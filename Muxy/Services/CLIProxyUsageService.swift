import Foundation

struct CLIProxyUsageEndpointCandidate: Equatable {
    let baseURL: URL
    let apiKey: String?
    let managementKey: String?
    let source: String

    init(baseURL: URL, apiKey: String? = nil, managementKey: String? = nil, source: String) {
        self.baseURL = baseURL.normalizedCLIProxyRoot
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.managementKey = managementKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.source = source
    }

    var credentialScore: Int {
        (apiKey == nil ? 0 : 2) + (managementKey == nil ? 0 : 1)
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

protocol CLIProxyLocalInstallationProbing: Sendable {
    func installationReport() -> CLIProxyLocalInstallationReport
}

struct CLIProxyUsageHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

struct CLIProxyLocalInstallationReport: Equatable {
    let binaryPath: String?
    let configPath: String?
    let usageStatisticsEnabled: Bool?
    let redisUsageQueueRetentionSeconds: Int?

    var findings: [String] {
        var result = [
            "local binary: \(binaryPath ?? "not found")",
            "config path: \(configPath ?? "not found")",
        ]
        if let usageStatisticsEnabled {
            result.append("config usage-statistics-enabled: \(usageStatisticsEnabled)")
        } else {
            result.append("config usage-statistics-enabled: unknown")
        }
        if let redisUsageQueueRetentionSeconds {
            result.append("config redis usage queue retention: \(redisUsageQueueRetentionSeconds)s")
        } else {
            result.append("config redis usage queue retention: unknown")
        }
        return result
    }
}

struct CLIProxyLocalInstallationProbe: CLIProxyLocalInstallationProbing {
    let homeDirectory: String
    let fileExists: @Sendable (String) -> Bool
    let dataReader: @Sendable (String) throws -> Data

    init(
        homeDirectory: String = NSHomeDirectory(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        dataReader: @escaping @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) {
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists
        self.dataReader = dataReader
    }

    func installationReport() -> CLIProxyLocalInstallationReport {
        let binaryPath = firstExistingPath([
            "/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi",
            "/opt/homebrew/bin/cliproxyapi",
            "/usr/local/bin/cliproxyapi",
        ])
        let configPath = firstExistingPath([
            "/opt/homebrew/etc/cliproxyapi.conf",
            "\(homeDirectory)/.config/cliproxyapi/config.yaml",
            "\(homeDirectory)/.cliproxyapi/config.yaml",
        ])
        let config = configPath.flatMap { try? dataReader($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return CLIProxyLocalInstallationReport(
            binaryPath: binaryPath,
            configPath: configPath,
            usageStatisticsEnabled: config.flatMap(Self.parseUsageStatisticsEnabled),
            redisUsageQueueRetentionSeconds: config.flatMap(Self.parseRedisUsageQueueRetentionSeconds)
        )
    }

    private func firstExistingPath(_ paths: [String]) -> String? {
        paths.first { fileExists($0) }
    }

    static func parseUsageStatisticsEnabled(_ config: String) -> Bool? {
        parseBoolValue(for: "usage-statistics-enabled", in: config)
    }

    static func parseRedisUsageQueueRetentionSeconds(_ config: String) -> Int? {
        parseIntegerValue(for: "redis-usage-queue-retention-seconds", in: config)
    }

    private static func parseBoolValue(for key: String, in config: String) -> Bool? {
        guard let value = scalarValue(for: key, in: config)?.lowercased() else { return nil }
        return switch value {
        case "true",
             "yes",
             "on",
             "1": true
        case "false",
             "no",
             "off",
             "0": false
        default: nil
        }
    }

    private static func parseIntegerValue(for key: String, in config: String) -> Int? {
        scalarValue(for: key, in: config).flatMap(Int.init)
    }

    private static func scalarValue(for key: String, in config: String) -> String? {
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let value = trimmed.dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .unquotedTOMLScalar
            return value.isEmpty ? nil : value
        }
        return nil
    }
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
        let apiKey = firstConfiguredValue(for: [
            "CLIPROXYAPI_API_KEY",
            "CLIPROXYAPI_KEY",
            "CLIPROXYAPI_TOKEN",
            "CLIPROXYAPI_BEARER_TOKEN",
        ])
        let managementKey = env["CLIPROXYAPI_MANAGEMENT_KEY"]
            ?? env["CLIPROXYAPI_REMOTE_MANAGEMENT_KEY"]
            ?? env["CLIPROXYAPI_MANAGEMENT_SECRET_KEY"]
        for key in ["CLIPROXYAPI_BASE_URL", "CLIPROXYAPI_URL"] {
            if let url = env[key].flatMap(URL.init(string:)), url.isLocalHTTPURL {
                candidates.append(
                    CLIProxyUsageEndpointCandidate(baseURL: url, apiKey: apiKey, managementKey: managementKey, source: key)
                )
            }
        }
        candidates.append(contentsOf: codexConfigCandidates(apiKey: apiKey, managementKey: managementKey))
        for rawURL in ["http://127.0.0.1:8317", "http://localhost:8317"] {
            if let url = URL(string: rawURL) {
                candidates.append(
                    CLIProxyUsageEndpointCandidate(baseURL: url, apiKey: apiKey, managementKey: managementKey, source: "default")
                )
            }
        }
        return dedupe(candidates)
    }

    private func codexConfigCandidates(apiKey: String?, managementKey: String?) -> [CLIProxyUsageEndpointCandidate] {
        let paths = [
            env["CODEX_HOME"].map { "\($0)/config.toml" },
            "\(homeDirectory)/.codex/config.toml",
            "\(homeDirectory)/.config/codex/config.toml",
        ].compactMap(\.self)

        return paths.flatMap { path -> [CLIProxyUsageEndpointCandidate] in
            guard fileExists(path), let data = try? dataReader(path) else { return [] }
            return Self.parseCodexConfig(data: data).map { candidate in
                CLIProxyUsageEndpointCandidate(
                    baseURL: candidate.baseURL,
                    apiKey: candidate.apiKey ?? apiKey,
                    managementKey: managementKey,
                    source: "codex-config"
                )
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
            } else if ["api_key", "experimental_bearer_token", "bearer_token"].contains(String(key)) {
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
        var indexesByBaseURL: [String: Int] = [:]
        var deduped: [CLIProxyUsageEndpointCandidate] = []
        for candidate in candidates {
            let key = candidate.baseURL.absoluteString
            if let existingIndex = indexesByBaseURL[key] {
                let existing = deduped[existingIndex]
                if candidate.credentialScore > existing.credentialScore {
                    deduped[existingIndex] = candidate
                }
                continue
            }
            indexesByBaseURL[key] = deduped.count
            deduped.append(candidate)
        }
        return deduped
    }

    private func firstConfiguredValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return nil
    }
}

private actor CLIProxyManagementProbeBackoff {
    static let shared = CLIProxyManagementProbeBackoff()

    private var blockedUntilByKey: [String: Date] = [:]

    func isBlocked(_ key: String, at now: Date) -> Bool {
        guard let blockedUntil = blockedUntilByKey[key] else { return false }
        if blockedUntil > now { return true }
        blockedUntilByKey.removeValue(forKey: key)
        return false
    }

    func recordFailure(_ key: String, at now: Date, duration: TimeInterval) {
        blockedUntilByKey[key] = now.addingTimeInterval(duration)
    }

    func recordSuccess(_ key: String) {
        blockedUntilByKey.removeValue(forKey: key)
    }
}

struct CLIProxyUsageService: CLIProxyUsageSnapshotServing {
    let endpointResolver: any CLIProxyUsageEndpointResolving
    let transport: any CLIProxyUsageTransport
    let localInstallationProbe: any CLIProxyLocalInstallationProbing
    let usageEventStore: any CLIProxyUsageEventPersisting
    let usageEventLookbackInterval: TimeInterval
    let usageEventRetentionInterval: TimeInterval
    let now: @Sendable () -> Date

    init(
        endpointResolver: any CLIProxyUsageEndpointResolving = CLIProxyUsageEndpointResolver(),
        transport: any CLIProxyUsageTransport = URLSessionCLIProxyUsageTransport(),
        localInstallationProbe: any CLIProxyLocalInstallationProbing = CLIProxyLocalInstallationProbe(),
        usageEventStore: any CLIProxyUsageEventPersisting = CLIProxyUsageSQLiteEventStore(),
        usageEventLookbackInterval: TimeInterval = 24 * 60 * 60,
        usageEventRetentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.endpointResolver = endpointResolver
        self.transport = transport
        self.localInstallationProbe = localInstallationProbe
        self.usageEventStore = usageEventStore
        self.usageEventLookbackInterval = usageEventLookbackInterval
        self.usageEventRetentionInterval = usageEventRetentionInterval
        self.now = now
    }

    func fetchUsageSnapshot() async -> CLIProxyUsageSnapshot {
        let candidates = endpointResolver.endpointCandidates()
        var failures: [CLIProxyUsageWarning] = []
        var authRequired: [(candidate: CLIProxyUsageEndpointCandidate, message: String)] = []

        for candidate in candidates {
            let health = await probeHealth(candidate: candidate)
            switch health {
            case let .reachable(version):
                let statsProbe = await fetchStats(candidate: candidate, version: version)
                let queueProbe = statsProbe.snapshot == nil
                    ? await fetchUsageQueueStats(candidate: candidate, version: version)
                    : StatsProbeResult(snapshot: nil, probeReport: [])
                let detectedBackend = statsProbe.snapshot?.statsBackend ?? queueProbe.snapshot?.statsBackend
                let capabilityProbe = await probeCapabilities(
                    candidate: candidate,
                    version: version,
                    statsProbe: statsProbe.probeReport + queueProbe.probeReport,
                    detectedStatsBackend: detectedBackend
                )
                if let stats = statsProbe.snapshot ?? queueProbe.snapshot {
                    return stats.withCapabilityReport(capabilityProbe)
                }
                return proxyOnlySnapshot(
                    candidate: candidate,
                    version: version,
                    statusMessage: "CLIProxyAPI is reachable, but no usage statistics backend was detected",
                    capabilityProbe: capabilityProbe
                )
            case let .needsAPIKey(message):
                authRequired.append((candidate, message))
                failures.append(
                    CLIProxyUsageWarning(
                        id: "auth-\(authRequired.count - 1)",
                        severity: .info,
                        message: "\(candidate.baseURL.absoluteString): \(message)"
                    )
                )
                continue
            case let .failed(message):
                failures.append(CLIProxyUsageWarning(id: "probe-\(failures.count)", severity: .warning, message: message))
            }
        }

        if let auth = authRequired.first {
            return proxyOnlySnapshot(
                candidate: auth.candidate,
                version: nil,
                statusMessage: auth.message,
                additionalWarnings: failures
            )
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
                guard response.isOpenAICompatibleModelsResponse else {
                    return .failed("\(candidate.baseURL.absoluteString) /v1/models did not return an OpenAI-compatible models payload")
                }
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

    private func fetchStats(candidate: CLIProxyUsageEndpointCandidate, version: String?) async -> StatsProbeResult {
        var reports: [String] = []
        for path in statsSnapshotPaths {
            var request = URLRequest(url: candidate.baseURL.appendingPathComponents(path))
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let apiKey = candidate.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            do {
                let response = try await transport.data(for: request)
                let label = "/\(path.joined(separator: "/"))"
                guard (200 ..< 300).contains(response.statusCode) else {
                    reports.append("\(label): HTTP \(response.statusCode)")
                    continue
                }
                reports.append("\(label): available")
                var snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(
                    from: response.data,
                    now: now(),
                    fallbackBaseURL: candidate.baseURL
                )
                if snapshot.version == nil, let version {
                    snapshot = snapshot.withVersion(version)
                }
                return StatsProbeResult(snapshot: snapshot, probeReport: reports)
            } catch {
                let label = "/\(path.joined(separator: "/"))"
                reports.append("\(label): failed")
                usageLogger.error("CLIProxyAPI usage stats parse failed for \(path.joined(separator: "/")): \(error.localizedDescription)")
            }
        }
        return StatsProbeResult(snapshot: nil, probeReport: reports)
    }

    private var statsSnapshotPaths: [[String]] {
        [
            ["v0", "usage", "snapshot"],
            ["api", "usage", "snapshot"],
            ["usage", "snapshot"],
        ]
    }

    private func fetchUsageQueueStats(candidate: CLIProxyUsageEndpointCandidate, version: String?) async -> StatsProbeResult {
        let label = "/v0/management/usage-queue"
        guard let managementKey = candidate.managementKey else {
            return StatsProbeResult(snapshot: nil, probeReport: ["\(label): not probed; local management key unavailable"])
        }
        let backoffKey = managementProbeBackoffKey(candidate: candidate, managementKey: managementKey)
        if await CLIProxyManagementProbeBackoff.shared.isBlocked(backoffKey, at: now()) {
            return StatsProbeResult(snapshot: nil, probeReport: ["\(label): backing off after recent management auth failure"])
        }

        var components = URLComponents(
            url: candidate.baseURL.appendingPathComponents(["v0", "management", "usage-queue"]),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "count", value: "128")]
        guard let url = components?.url else {
            return StatsProbeResult(snapshot: nil, probeReport: ["\(label): invalid local URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")

        do {
            let response = try await transport.data(for: request)
            guard (200 ..< 300).contains(response.statusCode) else {
                if response.statusCode == 401 {
                    await CLIProxyManagementProbeBackoff.shared.recordFailure(backoffKey, at: now(), duration: 30 * 60)
                    return StatsProbeResult(snapshot: nil, probeReport: ["\(label): requires local management key"])
                }
                if response.statusCode == 403 {
                    await CLIProxyManagementProbeBackoff.shared.recordFailure(backoffKey, at: now(), duration: 30 * 60)
                    return StatsProbeResult(snapshot: nil, probeReport: ["\(label): IP banned or forbidden"])
                }
                if response.statusCode == 404 {
                    return StatsProbeResult(snapshot: nil, probeReport: ["\(label): not exposed"])
                }
                return StatsProbeResult(snapshot: nil, probeReport: ["\(label): HTTP \(response.statusCode)"])
            }

            await CLIProxyManagementProbeBackoff.shared.recordSuccess(backoffKey)
            let fetchedAt = now()
            let queueEvents = try CLIProxyUsageQueueRecordParser.parseEvents(from: response.data)
            try persistUsageQueueEvents(queueEvents, fetchedAt: fetchedAt)
            let storedEvents = try usageEventStore.loadEvents(since: fetchedAt.addingTimeInterval(-usageEventLookbackInterval))
            let snapshot = CLIProxyUsageSnapshotBuilder.snapshot(
                baseURL: candidate.baseURL,
                version: version,
                statsBackend: .sqlite,
                events: storedEvents,
                fetchedAt: fetchedAt,
                warnings: [
                    CLIProxyUsageWarning(
                        id: "usage-queue-collector",
                        severity: .info,
                        message: "Collected \(queueEvents.count) CLIProxyAPI usage queue record(s) into app-owned SQLite"
                    ),
                ]
            )
            return StatsProbeResult(snapshot: snapshot, probeReport: ["\(label): available; collected \(queueEvents.count) record(s)"])
        } catch {
            usageLogger.error("CLIProxyAPI usage queue collection failed: \(error.localizedDescription)")
            return StatsProbeResult(snapshot: nil, probeReport: ["\(label): failed"])
        }
    }

    private func persistUsageQueueEvents(_ events: [CLIProxyUsageEvent], fetchedAt: Date) throws {
        let cutoff = fetchedAt.addingTimeInterval(-usageEventRetentionInterval)
        try usageEventStore.append(events, pruningBefore: cutoff)
    }

    private func managementProbeBackoffKey(candidate: CLIProxyUsageEndpointCandidate, managementKey: String) -> String {
        "\(candidate.baseURL.absoluteString)#\(managementKey.hashValue)"
    }

    private func proxyOnlySnapshot(
        candidate: CLIProxyUsageEndpointCandidate,
        version: String?,
        statusMessage: String,
        capabilityProbe: CLIProxyCapabilityProbeReport? = nil,
        additionalWarnings: [CLIProxyUsageWarning] = []
    ) -> CLIProxyUsageSnapshot {
        let probeWarning = capabilityProbe.map { report in
            CLIProxyUsageWarning(id: "capability-report", severity: .info, message: report.summary)
        }
        var missing = [
            CLIProxyMissingCapability(
                id: "usage-history",
                capability: "Usage history",
                reason: "No Redis-queue collector, app-owned SQLite snapshot endpoint, dashboard, or built-in stats source was detected"
            ),
            CLIProxyMissingCapability(
                id: "quota",
                capability: "Quota windows",
                reason: "No stats backend provided quota or reset-window data"
            ),
        ]
        if let capabilityProbe {
            missing.append(contentsOf: capabilityProbe.missingCapabilities)
        }
        return CLIProxyUsageSnapshot(
            fetchedAt: now(),
            baseURL: candidate.baseURL,
            isProxyReachable: true,
            version: version,
            statsBackend: capabilityProbe?.managementConfigAvailable == true ? .managementOnly : .proxyOnly,
            accounts: [],
            models: [],
            windows: [],
            velocities: [],
            warnings: [CLIProxyUsageWarning(id: "stats-unavailable", severity: .info, message: statusMessage)]
                + additionalWarnings
                + [probeWarning].compactMap(\.self),
            missingCapabilities: missing
        )
    }

    private func probeCapabilities(
        candidate: CLIProxyUsageEndpointCandidate,
        version: String?,
        statsProbe: [String],
        detectedStatsBackend: CLIProxyStatsBackend?
    ) async -> CLIProxyCapabilityProbeReport {
        var findings = ["endpoint source: \(candidate.source)"]
        let localReport = localInstallationProbe.installationReport()
        findings.append(contentsOf: localReport.findings)
        if let version {
            findings.append("version surface: /v1/models header \(version)")
        } else {
            findings.append("version surface: not exposed by /v1/models headers")
        }
        findings.append("stats surfaces: \(statsProbe.isEmpty ? "not probed" : statsProbe.joined(separator: "; "))")
        if let detectedStatsBackend {
            findings.append("detected stats backend: \(detectedStatsBackend.displayName)")
        }

        let shouldSkipExtraManagementProbes = statsProbe.contains { report in
            report.contains("/v0/management/usage-queue: requires local management key")
                || report.contains("/v0/management/usage-queue: IP banned")
                || report.contains("/v0/management/usage-queue: backing off")
        }
        let management: String
        let managementVersion: String
        if shouldSkipExtraManagementProbes {
            management = "not probed; usage queue auth failed"
            managementVersion = "not probed; usage queue auth failed"
        } else {
            management = await probeHTTPStatus(
                candidate: candidate,
                path: ["v0", "management", "config"],
                authorizationToken: candidate.managementKey
            )
            managementVersion = await probeHTTPStatus(
                candidate: candidate,
                path: ["v0", "management", "latest-version"],
                authorizationToken: candidate.managementKey
            )
        }
        findings.append("management/config: \(management)")
        findings.append("management/latest-version: \(managementVersion)")

        let hasSnapshotEndpoint = statsProbe.contains { report in
            report.contains(": available") && !report.contains("/v0/management/usage-queue")
        }
        let hasUsageQueueCollector = detectedStatsBackend == .usageQueue
            || detectedStatsBackend == .sqlite
            || statsProbe.contains { $0.contains("/v0/management/usage-queue: available") }
        findings
            .append(hasUsageQueueCollector ? "Redis usage queue collector: available via app-owned SQLite" :
                "Redis usage queue collector: not detected")
        findings
            .append(hasSnapshotEndpoint ? "external/built-in snapshot endpoint: available" :
                "external/built-in snapshot endpoint: not detected")

        var missing: [CLIProxyMissingCapability] = []
        if !hasUsageQueueCollector {
            let reason = if localReport.usageStatisticsEnabled == false {
                "Local CLIProxyAPI config disables usage-statistics-enabled"
            } else if localReport.usageStatisticsEnabled == true {
                "Local config enables the Redis-compatible usage queue, but no normalized collector snapshot was detected"
            } else {
                "No normalized local snapshot identified CLIProxyAPI Redis usage queue events"
            }
            missing.append(CLIProxyMissingCapability(
                id: "redis-collector",
                capability: "Redis usage queue collector",
                reason: reason
            ))
        }
        if !hasSnapshotEndpoint, !hasUsageQueueCollector {
            missing.append(CLIProxyMissingCapability(
                id: "external-collector",
                capability: "External or built-in usage collector",
                reason: "No local normalized snapshot endpoint responded"
            ))
        }
        if management != "available" {
            missing.append(CLIProxyMissingCapability(
                id: "management-api",
                capability: "Management API",
                reason: "Local management/config probe returned \(management)"
            ))
        }
        return CLIProxyCapabilityProbeReport(
            summary: findings.joined(separator: " | "),
            missingCapabilities: missing,
            managementConfigAvailable: management == "available"
        )
    }

    private func probeHTTPStatus(
        candidate: CLIProxyUsageEndpointCandidate,
        path: [String],
        authorizationToken: String?
    ) async -> String {
        guard let authorizationToken else {
            return "not probed; local management key unavailable"
        }
        var request = URLRequest(url: candidate.baseURL.appendingPathComponents(path))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        do {
            let response = try await transport.data(for: request)
            if (200 ..< 300).contains(response.statusCode) { return "available" }
            if response.statusCode == 401 || response.statusCode == 403 { return "requires local management key" }
            if response.statusCode == 404 { return "not exposed" }
            return "HTTP \(response.statusCode)"
        } catch {
            return "probe failed"
        }
    }

    private func version(from response: CLIProxyUsageHTTPResponse) -> String? {
        response.headers.first { key, _ in key.caseInsensitiveCompare("X-CLIProxyAPI-Version") == .orderedSame }?.value
            ?? response.headers.first { key, _ in key.caseInsensitiveCompare("Server") == .orderedSame }?.value
    }

    private struct StatsProbeResult {
        let snapshot: CLIProxyUsageSnapshot?
        let probeReport: [String]
    }

    private enum HealthProbeResult {
        case reachable(version: String?)
        case needsAPIKey(String)
        case failed(String)
    }
}

private struct CLIProxyCapabilityProbeReport {
    let summary: String
    let missingCapabilities: [CLIProxyMissingCapability]
    let managementConfigAvailable: Bool
}

private extension CLIProxyUsageHTTPResponse {
    var isOpenAICompatibleModelsResponse: Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["data"] is [Any]
        else { return false }
        return true
    }
}

private extension URL {
    func appendingPathComponents(_ components: [String]) -> URL {
        components.reduce(self) { url, component in
            url.appendingPathComponent(component)
        }
    }

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

private extension CLIProxyUsageSnapshot {
    func withVersion(_ version: String) -> CLIProxyUsageSnapshot {
        CLIProxyUsageSnapshot(
            fetchedAt: fetchedAt,
            baseURL: baseURL,
            isProxyReachable: isProxyReachable,
            version: version,
            statsBackend: statsBackend,
            accounts: accounts,
            models: models,
            sessions: sessions,
            windows: windows,
            velocities: velocities,
            warnings: warnings,
            missingCapabilities: missingCapabilities
        )
    }

    func withCapabilityReport(_ report: CLIProxyCapabilityProbeReport) -> CLIProxyUsageSnapshot {
        CLIProxyUsageSnapshot(
            fetchedAt: fetchedAt,
            baseURL: baseURL,
            isProxyReachable: isProxyReachable,
            version: version,
            statsBackend: statsBackend,
            accounts: accounts,
            models: models,
            sessions: sessions,
            windows: windows,
            velocities: velocities,
            warnings: warnings + [CLIProxyUsageWarning(id: "capability-report", severity: .info, message: report.summary)],
            missingCapabilities: missingCapabilities + report.missingCapabilities.filter { capability in
                !missingCapabilities.contains { $0.id == capability.id }
            }
        )
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
