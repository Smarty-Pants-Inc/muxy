import Foundation
import Testing

@testable import Muxy

@Suite("CLIProxyUsageParserProvider")
struct CLIProxyUsageParserProviderTests {
    @Test("fixture parser explains missing stats without fake windows")
    func noStatsFixtureExplainsMissingCapability() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let data = Data(
            """
            {
              "baseURL": "http://127.0.0.1:8317",
              "fetchedAt": "2026-05-10T12:00:00Z",
              "reachable": true,
              "version": "CLIProxyAPI Version: 6.10.5",
              "statsBackend": "proxyOnly",
              "diagnostics": [
                {"label": "Authorization", "value": "Bearer local_secret_token_123456789"}
              ]
            }
            """.utf8
        )

        let snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(from: data, now: now)
        #expect(snapshot.isProxyReachable)
        #expect(snapshot.statsBackend == .proxyOnly)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.velocities.isEmpty)
        #expect(snapshot.missingCapabilities.contains { $0.id == "usage-history" })
        #expect(snapshot.diagnostics.first?.value.contains("local_secret_token") == false)
        #expect(snapshot.warnings.contains { $0.id == "stats-unavailable" })
    }

    @Test("fixture parser redacts account, session, warning, and diagnostic secrets")
    func redactsUnsafeFields() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let data = Data(
            """
            {
              "baseURL": "http://127.0.0.1:8317",
              "reachable": true,
              "statsBackend": "usageQueue",
              "accounts": [
                {
                  "id": "paul@example.com",
                  "displayName": "paul@example.com",
                  "providerKind": "codex",
                  "status": "active",
                  "quota": {
                    "limitTokens": 10000,
                    "usedTokens": 1000,
                    "resetsAt": "2026-05-10T13:00:00Z"
                  }
                }
              ],
              "events": [
                {
                  "id": "evt_secret_token_123456789",
                  "timestamp": "2026-05-10T11:59:30Z",
                  "accountID": "paul@example.com",
                  "accountDisplayName": "paul@example.com",
                  "providerKind": "codex",
                  "model": "gpt-5.5",
                  "sessionID": "conversation-with-secret-token-123456789",
                  "promptTokens": 100,
                  "completionTokens": 50
                }
              ],
              "warnings": [
                {"id": "unsafe", "severity": "warning", "message": "config URL http://user:password@localhost:8317?api_key=secret-token"}
              ],
              "diagnostics": [
                {"label": "Header", "value": "Authorization=secret-token-123456789"}
              ]
            }
            """.utf8
        )

        let snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(from: data, now: now)
        let account = try #require(snapshot.accounts.first)
        #expect(!account.id.contains("@"))
        #expect(!account.displayName.contains("@"))
        #expect(snapshot.warnings.first?.message.contains("secret-token") == false)
        #expect(snapshot.warnings.first?.message.contains("password") == false)
        #expect(snapshot.diagnostics.first?.value.contains("secret-token") == false)
        #expect(snapshot.windows.first { $0.id == "1m" }?.totalTokens == 150)
    }

    @Test("provider maps offline, no-stats, and stats snapshots to safe AI usage snapshots")
    func providerSnapshots() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let offline = CLIProxyUsageSnapshot(
            fetchedAt: now,
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            isProxyReachable: false,
            version: nil,
            statsBackend: .unavailable,
            accounts: [],
            models: [],
            windows: [],
            velocities: [],
            warnings: [],
            diagnostics: [],
            missingCapabilities: []
        )
        let offlineSnapshot = await CLIProxyUsageProvider(service: StaticCLIProxyUsageService(snapshot: offline)).fetchUsageSnapshot()
        Self.expectUnavailable(offlineSnapshot, contains: "not detected")

        let noStats = try CLIProxyUsageFixtureParser.parseSnapshot(
            from: Data(#"{"baseURL":"http://127.0.0.1:8317","reachable":true,"statsBackend":"proxyOnly"}"#.utf8),
            now: now
        )
        let noStatsSnapshot = await CLIProxyUsageProvider(service: StaticCLIProxyUsageService(snapshot: noStats)).fetchUsageSnapshot()
        Self.expectUnavailable(noStatsSnapshot, contains: "Usage history")

        let stats = try CLIProxyUsageFixtureParser.parseSnapshot(from: Self.statsFixtureData(), now: now)
        let statsSnapshot = await CLIProxyUsageProvider(service: StaticCLIProxyUsageService(snapshot: stats)).fetchUsageSnapshot()
        #expect(statsSnapshot.providerID == "cliproxyapi")
        if case .available = statsSnapshot.state {
            #expect(statsSnapshot.rows.contains { $0.label == "Hourly tokens" })
            #expect(statsSnapshot.rows.contains { $0.label == "Primary capacity" })
            #expect(!statsSnapshot.rows.contains { ($0.detail ?? "").contains("secret") })
        } else {
            Issue.record("Expected available CLIProxyAPI snapshot")
        }
    }

    @Test("service detects offline, no-stats, and stats-available local probes")
    func serviceDetectionFixtures() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let candidate = CLIProxyUsageEndpointCandidate(baseURL: URL(string: "http://127.0.0.1:8317")!, apiKey: "test-key", source: "test")

        let offlineService = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { _ in throw URLError(.cannotConnectToHost) },
            now: { now }
        )
        let offline = await offlineService.fetchUsageSnapshot()
        #expect(!offline.isProxyReachable)
        #expect(offline.statsBackend == .unavailable)

        let noStatsService = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: ["X-CLIProxyAPI-Version": "6.10.5"], data: Data(#"{"data":[]}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            now: { now }
        )
        let noStats = await noStatsService.fetchUsageSnapshot()
        #expect(noStats.isProxyReachable)
        #expect(noStats.statsBackend == .proxyOnly)
        #expect(noStats.windows.isEmpty)

        let statsService = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: ["X-CLIProxyAPI-Version": "6.10.5"], data: Data(#"{"data":[]}"#.utf8))
                }
                if request.url?.path == "/v0/usage/snapshot" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Self.statsFixtureData())
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            now: { now }
        )
        let stats = await statsService.fetchUsageSnapshot()
        #expect(stats.isProxyReachable)
        #expect(stats.statsBackend == CLIProxyStatsBackend.usageQueue)
        #expect(stats.windows.first { $0.id == "1m" }?.totalTokens == 150)
    }

    @Test("codex config detection only returns local endpoints")
    func codexConfigDetectionIsLocalOnly() {
        let config = Data(
            """
            [model_providers.remote]
            base_url = "https://api.example.com/v1"
            api_key = "remote-secret"

            [model_providers.cliproxy]
            base_url = "http://127.0.0.1:8317/v1"
            api_key = "local-test-token"
            """.utf8
        )

        let candidates = CLIProxyUsageEndpointResolver.parseCodexConfig(data: config)
        #expect(candidates.count == 1)
        #expect(candidates.first?.baseURL.absoluteString == "http://127.0.0.1:8317")
        #expect(candidates.first?.apiKey == "local-test-token")
    }

    private static func statsFixtureData() -> Data {
        Data(
            """
            {
              "baseURL": "http://127.0.0.1:8317",
              "reachable": true,
              "statsBackend": "usageQueue",
              "accounts": [
                {
                  "id": "acct-local",
                  "displayName": "Local Account",
                  "providerKind": "codex",
                  "status": "active",
                  "activeSessionCount": 0,
                  "quota": {
                    "limitTokens": 10000,
                    "usedTokens": 4000,
                    "resetsAt": "2026-05-10T13:00:00Z"
                  }
                }
              ],
              "events": [
                {
                  "id": "evt-1",
                  "timestamp": "2026-05-10T11:59:30Z",
                  "accountID": "acct-local",
                  "providerKind": "codex",
                  "model": "gpt-5.5",
                  "sessionID": "session-local",
                  "promptTokens": 100,
                  "completionTokens": 50
                },
                {
                  "id": "evt-2",
                  "timestamp": "2026-05-10T11:57:00Z",
                  "accountID": "acct-local",
                  "providerKind": "codex",
                  "model": "gpt-5.5",
                  "sessionID": "session-local",
                  "promptTokens": 200,
                  "completionTokens": 100
                }
              ]
            }
            """.utf8
        )
    }

    private static func expectUnavailable(_ snapshot: AIProviderUsageSnapshot, contains expected: String) {
        if case let .unavailable(message) = snapshot.state {
            #expect(message.localizedCaseInsensitiveContains(expected))
        } else {
            Issue.record("Expected unavailable state")
        }
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

private struct StaticCLIProxyUsageService: CLIProxyUsageSnapshotServing {
    let snapshot: CLIProxyUsageSnapshot

    func fetchUsageSnapshot() async -> CLIProxyUsageSnapshot {
        snapshot
    }
}

private struct StaticResolver: CLIProxyUsageEndpointResolving {
    let candidates: [CLIProxyUsageEndpointCandidate]

    func endpointCandidates() -> [CLIProxyUsageEndpointCandidate] {
        candidates
    }
}

private struct ClosureTransport: CLIProxyUsageTransport {
    let handler: @Sendable (URLRequest) throws -> CLIProxyUsageHTTPResponse

    func data(for request: URLRequest) async throws -> CLIProxyUsageHTTPResponse {
        try handler(request)
    }
}
