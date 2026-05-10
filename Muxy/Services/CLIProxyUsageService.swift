import Foundation

struct CLIProxyUsageEndpointCandidate: Equatable {
    let baseURL: URL
    let apiKey: String?
    let source: String

    init(baseURL: URL, apiKey: String? = nil, source: String) {
        self.baseURL = baseURL.normalizedCLIProxyRoot
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.source = source
    }
}

protocol CLIProxyUsageEndpointResolving: Sendable {
    func endpointCandidates() -> [CLIProxyUsageEndpointCandidate]
}

protocol CLIProxyUsageTransport: Sendable {
    func data(for request: URLRequest) async throws -> CLIProxyUsageHTTPResponse
}

protocol CLIProxyUsageSnapshotServing: Sendable {
    func fetchUsageSnapshot() async -> CLIProxyUsageSnapshot
}

struct CLIProxyUsageHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

struct URLSessionCLIProxyUsageTransport: CLIProxyUsageTransport {
    func data(for request: URLRequest) async throws -> CLIProxyUsageHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = "\(entry.value)"
        }
        return CLIProxyUsageHTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }
}

struct CLIProxyUsageEndpointResolver: CLIProxyUsageEndpointResolving {
    let env: [String: String]
    let homeDirectory: String
    let fileExists: @Sendable (String) -> Bool
    let dataReader: @Sendable (String) throws -> Data

    init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        dataReader: @escaping @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) {
        self.env = env
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists
        self.dataReader = dataReader
    }

    func endpointCandidates() -> [CLIProxyUsageEndpointCandidate] {
        var candidates: [CLIProxyUsageEndpointCandidate] = []
        for key in ["CLIPROXYAPI_BASE_URL", "CLIPROXYAPI_URL"] {
            if let url = env[key].flatMap(URL.init(string:)), url.isLocalHTTPURL {
                candidates.append(CLIProxyUsageEndpointCandidate(baseURL: url, source: key))
            }
        }
        candidates.append(contentsOf: codexConfigCandidates())
        for rawURL in ["http://127.0.0.1:8317", "http://localhost:8317"] {
            if let url = URL(string: rawURL) {
                candidates.append(CLIProxyUsageEndpointCandidate(baseURL: url, source: "default"))
            }
        }
        return dedupe(candidates)
    }

    private func codexConfigCandidates() -> [CLIProxyUsageEndpointCandidate] {
        let paths = [
            env["CODEX_HOME"].map { "\($0)/config.toml" },
            "\(homeDirectory)/.codex/config.toml",
            "\(homeDirectory)/.config/codex/config.toml",
        ].compactMap(\.self)

        return paths.flatMap { path -> [CLIProxyUsageEndpointCandidate] in
            guard fileExists(path), let data = try? dataReader(path) else { return [] }
            return Self.parseCodexConfig(data: data).map { candidate in
                CLIProxyUsageEndpointCandidate(baseURL: candidate.baseURL, apiKey: candidate.apiKey, source: "codex-config")
            }
        }
    }

    static func parseCodexConfig(data: Data) -> [CLIProxyUsageEndpointCandidate] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var currentBaseURL: URL?
        var currentAPIKey: String?
        var candidates: [CLIProxyUsageEndpointCandidate] = []

        func flush() {
            guard let baseURL = currentBaseURL, baseURL.isLocalHTTPURL else { return }
            candidates.append(CLIProxyUsageEndpointCandidate(baseURL: baseURL, apiKey: currentAPIKey, source: "codex-config"))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                flush()
                currentBaseURL = nil
                currentAPIKey = nil
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines).unquotedTOMLScalar
            if key == "base_url", let url = URL(string: value), url.isLocalHTTPURL {
                currentBaseURL = url
            } else if key == "api_key" {
                currentAPIKey = value
            }
        }
        flush()
        return dedupe(candidates)
    }

    private func dedupe(_ candidates: [CLIProxyUsageEndpointCandidate]) -> [CLIProxyUsageEndpointCandidate] {
        Self.dedupe(candidates)
    }

    private static func dedupe(_ candidates: [CLIProxyUsageEndpointCandidate]) -> [CLIProxyUsageEndpointCandidate] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let key = candidate.baseURL.absoluteString
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

struct CLIProxyUsageService: CLIProxyUsageSnapshotServing {
    let endpointResolver: any CLIProxyUsageEndpointResolving
    let transport: any CLIProxyUsageTransport
    let now: @Sendable () -> Date

    init(
        endpointResolver: any CLIProxyUsageEndpointResolving = CLIProxyUsageEndpointResolver(),
        transport: any CLIProxyUsageTransport = URLSessionCLIProxyUsageTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.endpointResolver = endpointResolver
        self.transport = transport
        self.now = now
    }

    func fetchUsageSnapshot() async -> CLIProxyUsageSnapshot {
        let candidates = endpointResolver.endpointCandidates()
        var failures: [CLIProxyUsageWarning] = []

        for candidate in candidates {
            let health = await probeHealth(candidate: candidate)
            switch health {
            case let .reachable(version):
                if let stats = await fetchStats(candidate: candidate, version: version) {
                    return stats
                }
                return proxyOnlySnapshot(
                    candidate: candidate,
                    version: version,
                    statusMessage: "CLIProxyAPI is reachable, but no usage statistics backend was detected"
                )
            case let .needsAPIKey(message):
                return proxyOnlySnapshot(candidate: candidate, version: nil, statusMessage: message)
            case let .failed(message):
                failures.append(CLIProxyUsageWarning(id: "probe-\(failures.count)", severity: .warning, message: message))
            }
        }

        let baseURL = candidates.first?.baseURL ?? defaultBaseURL
        var warnings = failures
        warnings.append(
            CLIProxyUsageWarning(
                id: "offline",
                severity: .warning,
                message: "CLIProxyAPI was not detected on local endpoints"
            )
        )
        return CLIProxyUsageSnapshot(
            fetchedAt: now(),
            baseURL: baseURL,
            isProxyReachable: false,
            version: nil,
            statsBackend: .unavailable,
            accounts: [],
            models: [],
            windows: [],
            velocities: [],
            warnings: warnings,
            diagnostics: [CLIProxyUsageDiagnostic(label: "Detection", value: "No local CLIProxyAPI endpoint responded")],
            missingCapabilities: [
                CLIProxyMissingCapability(
                    id: "proxy",
                    capability: "Proxy reachability",
                    reason: "No local CLIProxyAPI-compatible endpoint responded"
                ),
                CLIProxyMissingCapability(
                    id: "usage-history",
                    capability: "Usage history",
                    reason: "No stats source can be probed until the proxy is reachable"
                ),
            ]
        )
    }

    private var defaultBaseURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 8317
        return components.url ?? URL(fileURLWithPath: "/")
    }

    private func probeHealth(candidate: CLIProxyUsageEndpointCandidate) async -> HealthProbeResult {
        var request = URLRequest(url: candidate.baseURL.appendingPathComponent("v1").appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = candidate.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let response = try await transport.data(for: request)
            if (200 ..< 300).contains(response.statusCode) {
                return .reachable(version: version(from: response))
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                return .needsAPIKey("CLIProxyAPI models endpoint requires a local API key; usage history was not probed")
            }
            return .failed("\(candidate.baseURL.absoluteString) /v1/models returned HTTP \(response.statusCode)")
        } catch {
            return .failed("\(candidate.baseURL.absoluteString) probe failed: \(error.localizedDescription)")
        }
    }

    private func fetchStats(candidate: CLIProxyUsageEndpointCandidate, version: String?) async -> CLIProxyUsageSnapshot? {
        var request = URLRequest(url: candidate.baseURL.appendingPathComponent("v0").appendingPathComponent("usage")
            .appendingPathComponent("snapshot"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = candidate.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let response = try await transport.data(for: request)
            guard (200 ..< 300).contains(response.statusCode) else { return nil }
            var snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(from: response.data, now: now(), fallbackBaseURL: candidate.baseURL)
            if snapshot.version == nil, let version {
                snapshot = CLIProxyUsageSnapshot(
                    fetchedAt: snapshot.fetchedAt,
                    baseURL: snapshot.baseURL,
                    isProxyReachable: snapshot.isProxyReachable,
                    version: version,
                    statsBackend: snapshot.statsBackend,
                    accounts: snapshot.accounts,
                    models: snapshot.models,
                    windows: snapshot.windows,
                    velocities: snapshot.velocities,
                    warnings: snapshot.warnings,
                    diagnostics: snapshot.diagnostics,
                    missingCapabilities: snapshot.missingCapabilities
                )
            }
            return snapshot
        } catch {
            usageLogger.error("CLIProxyAPI usage stats parse failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func proxyOnlySnapshot(
        candidate: CLIProxyUsageEndpointCandidate,
        version: String?,
        statusMessage: String
    ) -> CLIProxyUsageSnapshot {
        CLIProxyUsageSnapshot(
            fetchedAt: now(),
            baseURL: candidate.baseURL,
            isProxyReachable: true,
            version: version,
            statsBackend: .proxyOnly,
            accounts: [],
            models: [],
            windows: [],
            velocities: [],
            warnings: [CLIProxyUsageWarning(id: "stats-unavailable", severity: .info, message: statusMessage)],
            diagnostics: [
                CLIProxyUsageDiagnostic(label: "Base URL", value: candidate.baseURL.absoluteString),
                CLIProxyUsageDiagnostic(label: "Stats backend", value: "Not detected"),
            ],
            missingCapabilities: [
                CLIProxyMissingCapability(
                    id: "usage-history",
                    capability: "Usage history",
                    reason: "No usage queue, collector, dashboard, or built-in stats source was detected"
                ),
                CLIProxyMissingCapability(
                    id: "quota",
                    capability: "Quota windows",
                    reason: "No stats backend provided quota or reset-window data"
                ),
            ]
        )
    }

    private func version(from response: CLIProxyUsageHTTPResponse) -> String? {
        response.headers.first { key, _ in key.caseInsensitiveCompare("X-CLIProxyAPI-Version") == .orderedSame }?.value
            ?? response.headers.first { key, _ in key.caseInsensitiveCompare("Server") == .orderedSame }?.value
    }

    private enum HealthProbeResult {
        case reachable(version: String?)
        case needsAPIKey(String)
        case failed(String)
    }
}

private extension URL {
    var isLocalHTTPURL: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    var normalizedCLIProxyRoot: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        if components.path == "/v1" || components.path.hasSuffix("/v1") {
            components.path = String(components.path.dropLast(3))
            if components.path == "/" {
                components.path = ""
            }
        }
        return components.url ?? self
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var unquotedTOMLScalar: String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }
}
