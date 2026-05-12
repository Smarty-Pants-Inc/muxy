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
              "statsBackend": "proxyOnly"
            }
            """.utf8
        )

        let snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(from: data, now: now)
        #expect(snapshot.isProxyReachable)
        #expect(snapshot.statsBackend == .proxyOnly)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.velocities.isEmpty)
        #expect(snapshot.missingCapabilities.contains { $0.id == "usage-history" })
        #expect(snapshot.warnings.contains { $0.id == "stats-unavailable" })
    }

    @Test("fixture parser redacts account, session, and warning secrets")
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
                  "lastUsedAt": "2026-05-10T11:58:00Z",
                  "recentFailure": {"occurredAt": "2026-05-10T11:56:00Z", "message": "rate_limit token secret-token-123456789 sk-1234567890abcdefXYZ"},
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
                  "completionTokens": 50,
                  "cacheReadTokens": 25,
                  "cacheWriteTokens": 5,
                  "latencyMS": 1500,
                  "timeToFirstTokenMS": 250,
                  "generationDurationMS": 1000,
                  "costEstimateUSD": 0.012
                }
              ],
              "warnings": [
                {
                  "id": "unsafe",
                  "severity": "warning",
                  "message": "config URL http://user:password@localhost:8317?api_key=secret-token sk-proj-1234567890abcdefXYZ management_key=mgmt-secret-123456789 remote-management.secret-key: remote-secret-123456789"
                }
              ]
            }
            """.utf8
        )

        let snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(from: data, now: now)
        let account = try #require(snapshot.accounts.first)
        #expect(!account.id.contains("@"))
        #expect(!account.displayName.contains("@"))
        #expect(snapshot.warnings.first?.message.contains("secret-token") == false)
        #expect(snapshot.warnings.first?.message.contains("sk-proj-1234567890abcdefXYZ") == false)
        #expect(snapshot.warnings.first?.message.contains("mgmt-secret-123456789") == false)
        #expect(snapshot.warnings.first?.message.contains("remote-secret-123456789") == false)
        #expect(snapshot.warnings.first?.message.contains("password") == false)
        let expectedLastUsedAt = try #require(Self.date("2026-05-10T11:58:00Z"))
        #expect(account.lastUsedAt == expectedLastUsedAt)
        #expect(account.recentFailure?.message.contains("secret-token") == false)
        #expect(account.recentFailure?.message.contains("sk-1234567890abcdefXYZ") == false)
        #expect(snapshot.sessions.first?.id.contains("secret-token") == false)
        let oneMinute = try #require(snapshot.windows.first { $0.id == "1m" })
        #expect(oneMinute.totalTokens == 150)
        #expect(oneMinute.cacheReadTokens == 25)
        #expect(oneMinute.cacheWriteTokens == 5)
        #expect(oneMinute.costEstimateUSD == 0.012)
        let model = try #require(snapshot.models.first)
        #expect(model.averageLatencyMS == 1500)
        #expect(model.averageTimeToFirstTokenMS == 250)
        #expect(model.generationTokensPerSecond == 50)
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
            #expect(statsSnapshot.rows.contains { $0.label == "Estimated cost" })
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
                    return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
                }
                if request.url?.path == "/api/usage/snapshot" {
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

    @Test("service continues after an auth-required candidate to find a credentialed local endpoint")
    func serviceContinuesAfterAuthRequiredCandidate() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let authRequired = CLIProxyUsageEndpointCandidate(baseURL: URL(string: "http://localhost:8317")!, source: "default")
        let credentialed = CLIProxyUsageEndpointCandidate(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            apiKey: "local-api-key",
            source: "codex-config"
        )
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [authRequired, credentialed]),
            transport: ClosureTransport { request in
                if request.url?.host == "localhost", request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 401, headers: [:], data: Data())
                }
                if request.url?.host == "127.0.0.1", request.url?.path == "/v1/models" {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-api-key")
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: ["X-CLIProxyAPI-Version": "6.10.5"], data: Data(#"{"data":[]}"#.utf8))
                }
                if request.url?.host == "127.0.0.1", request.url?.path == "/v0/usage/snapshot" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Self.statsFixtureData())
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()

        #expect(snapshot.isProxyReachable)
        #expect(snapshot.statsBackend == .usageQueue)
        #expect(snapshot.baseURL.absoluteString == "http://127.0.0.1:8317")
        #expect(snapshot.windows.first { $0.id == "1m" }?.totalTokens == 150)
    }

    @Test("usage queue parser normalizes records and redacts secrets")
    func usageQueueParserNormalizesAndRedactsRecords() throws {
        let events = try CLIProxyUsageQueueRecordParser.parseEvents(from: Self.usageQueueData())

        let event = try #require(events.first)
        #expect(event.providerKind == "codex")
        #expect(event.model == "gpt-5.5")
        #expect(event.promptTokens == 100)
        #expect(event.completionTokens == 25)
        #expect(event.totalTokens == 125)
        #expect(event.cacheReadTokens == 40)
        #expect(event.latencyMS == 1200)
        #expect(event.accountID?.contains("sk-proj") == false)
        #expect(event.accountDisplayName?.contains("example.com") == false)
        #expect(event.sessionID == nil)
        #expect(event.errorCode == nil)
    }

    @Test("service drains management usage queue into local SQLite-backed history")
    func serviceCollectsUsageQueueIntoLocalHistory() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let candidate = CLIProxyUsageEndpointCandidate(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            apiKey: "local-api-key",
            managementKey: "local-management-key",
            source: "test"
        )
        let store = InMemoryCLIProxyUsageEventStore()
        let requestLog = RequestLog()
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                requestLog.append(request)
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: ["X-CLIProxyAPI-Version": "6.10.5"], data: Data(#"{"data":[]}"#.utf8))
                }
                if request.url?.path == "/v0/management/usage-queue" {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-management-key")
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Self.usageQueueData())
                }
                if request.url?.path == "/v0/management/config" || request.url?.path == "/v0/management/latest-version" {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-management-key")
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            usageEventStore: store,
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()

        #expect(snapshot.isProxyReachable)
        #expect(snapshot.statsBackend == .sqlite)
        #expect(snapshot.windows.first { $0.id == "1m" }?.totalTokens == 125)
        #expect(snapshot.windows.first { $0.id == "1m" }?.cacheReadTokens == 40)
        #expect(snapshot.models.first?.model == "gpt-5.5")
        #expect(snapshot.accounts.first?.displayName.contains("example.com") == false)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.missingCapabilities.contains { $0.id == "agent-attribution" })
        #expect(snapshot.warnings.contains { $0.id == "usage-queue-collector" && $0.message.contains("1") })
        #expect(snapshot.warnings.contains { $0.id == "capability-report" && $0.message.contains("usage-queue: available") })
        #expect(!snapshot.missingCapabilities.contains { $0.id == "usage-history" })
        #expect(!snapshot.missingCapabilities.contains { $0.id == "redis-collector" })
        #expect(requestLog.paths.contains("/v0/management/usage-queue"))
    }

    @Test("service reports empty queue collector without fake zero windows")
    func serviceReportsEmptyQueueCollectorWithoutFakeZeroWindows() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let candidate = CLIProxyUsageEndpointCandidate(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            apiKey: "local-api-key",
            managementKey: "local-management-key",
            source: "test"
        )
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"data":[]}"#.utf8))
                }
                if request.url?.path == "/v0/management/usage-queue" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"[]"#.utf8))
                }
                if request.url?.path == "/v0/management/config" || request.url?.path == "/v0/management/latest-version" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            usageEventStore: InMemoryCLIProxyUsageEventStore(),
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()
        let providerSnapshot = CLIProxyUsageProvider.providerSnapshot(from: snapshot)

        #expect(snapshot.statsBackend == .sqlite)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.velocities.isEmpty)
        #expect(snapshot.warnings.contains { $0.id == "collector-empty" })
        Self.expectUnavailable(providerSnapshot, contains: "no usage events")
    }

    @Test("service replays persisted queue history when the next queue poll is empty")
    func serviceReplaysPersistedUsageQueueHistory() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let candidate = CLIProxyUsageEndpointCandidate(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            apiKey: "local-api-key",
            managementKey: "local-management-key",
            source: "test"
        )
        let store = InMemoryCLIProxyUsageEventStore()
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"data":[]}"#.utf8))
                }
                if request.url?.path == "/v0/management/usage-queue" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"[]"#.utf8))
                }
                if request.url?.path == "/v0/management/config" || request.url?.path == "/v0/management/latest-version" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            usageEventStore: store,
            now: { now }
        )
        try store.append(try CLIProxyUsageQueueRecordParser.parseEvents(from: Self.usageQueueData()), pruningBefore: nil)

        let snapshot = await service.fetchUsageSnapshot()

        #expect(snapshot.statsBackend == .sqlite)
        #expect(snapshot.windows.first { $0.id == "1m" }?.totalTokens == 125)
        #expect(snapshot.warnings.contains { $0.id == "usage-queue-collector" && $0.message.contains("0") })
    }

    @Test("service backs off after a management key failure to avoid lockout loops")
    func serviceBacksOffAfterManagementAuthFailure() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let requestLog = RequestLog()
        let candidate = CLIProxyUsageEndpointCandidate(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            apiKey: "local-api-key",
            managementKey: "bad-management-key",
            source: "test"
        )
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                requestLog.append(request)
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"data":[]}"#.utf8))
                }
                if request.url?.path == "/v0/management/usage-queue" {
                    return CLIProxyUsageHTTPResponse(statusCode: 401, headers: [:], data: Data())
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            now: { now }
        )

        let first = await service.fetchUsageSnapshot()
        let second = await service.fetchUsageSnapshot()

        #expect(first.statsBackend == .proxyOnly)
        #expect(second.statsBackend == .proxyOnly)
        #expect(requestLog.paths.filter { $0 == "/v0/management/usage-queue" }.count == 1)
        #expect(!requestLog.paths.contains("/v0/management/config"))
        #expect(!requestLog.paths.contains("/v0/management/latest-version"))
        #expect(second.warnings.contains { $0.id == "capability-report" && $0.message.contains("backing off") })
    }

    @Test("service reports capability probes without touching management endpoints unless a management key is configured")
    func capabilityReportAvoidsUnauthenticatedManagementProbes() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let requestLog = RequestLog()
        let candidate = CLIProxyUsageEndpointCandidate(baseURL: URL(string: "http://127.0.0.1:8317")!, apiKey: "test-key", source: "test")
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                requestLog.append(request)
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: ["X-CLIProxyAPI-Version": "6.10.5"], data: Data(#"{"data":[]}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()

        #expect(snapshot.statsBackend == .proxyOnly)
        #expect(snapshot.warnings.contains { $0.id == "capability-report" && $0.message.contains("stats surfaces") })
        #expect(snapshot.missingCapabilities.contains { $0.id == "management-api" && $0.reason.contains("key unavailable") })
        #expect(!requestLog.paths.contains("/v0/management/config"))
        #expect(!requestLog.paths.contains("/v0/management/latest-version"))
    }

    @Test("service uses management key only for management capability probes")
    func capabilityReportUsesConfiguredManagementKey() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let requestLog = RequestLog()
        let candidate = CLIProxyUsageEndpointCandidate(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            apiKey: "local-api-key",
            managementKey: "local-management-key",
            source: "test"
        )
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                requestLog.append(request)
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: ["X-CLIProxyAPI-Version": "6.10.5"], data: Data(#"{"data":[]}"#.utf8))
                }
                if request.url?.path == "/v0/management/config" || request.url?.path == "/v0/management/latest-version" {
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-management-key")
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()

        #expect(snapshot.statsBackend == .managementOnly)
        #expect(requestLog.paths.contains("/v0/management/config"))
        #expect(requestLog.paths.contains("/v0/management/latest-version"))
        #expect(!snapshot.missingCapabilities.contains { $0.id == "management-api" })
    }

    @Test("service rejects non OpenAI-compatible models payloads")
    func serviceRejectsInvalidModelsPayload() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [
                CLIProxyUsageEndpointCandidate(baseURL: URL(string: "http://127.0.0.1:8317")!, apiKey: "test-key", source: "test"),
            ]),
            transport: ClosureTransport { request in
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"ok":true}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()
        #expect(!snapshot.isProxyReachable)
        #expect(snapshot.warnings.contains { $0.message.contains("OpenAI-compatible models payload") })
    }

    @Test("local installation probe reads Homebrew binary and usage queue config")
    func localInstallationProbeReadsConfig() throws {
        let configPath = "/opt/homebrew/etc/cliproxyapi.conf"
        let binaryPath = "/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi"
        let probe = CLIProxyLocalInstallationProbe(
            homeDirectory: "/Users/example",
            fileExists: { $0 == configPath || $0 == binaryPath },
            dataReader: { path in
                #expect(path == configPath)
                return Data(
                    """
                    host: "127.0.0.1"
                    port: 8317
                    usage-statistics-enabled: true
                    redis-usage-queue-retention-seconds: 3600
                    """.utf8
                )
            }
        )

        let report = probe.installationReport()

        #expect(report.binaryPath == binaryPath)
        #expect(report.configPath == configPath)
        #expect(report.usageStatisticsEnabled == true)
        #expect(report.redisUsageQueueRetentionSeconds == 3600)
        #expect(report.findings.contains("config usage-statistics-enabled: true"))
        #expect(report.findings.contains("config redis usage queue retention: 3600s"))
    }

    @Test("capability report includes local install findings and enabled queue explanation")
    func capabilityReportIncludesLocalInstallFindings() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let candidate = CLIProxyUsageEndpointCandidate(baseURL: URL(string: "http://127.0.0.1:8317")!, apiKey: "test-key", source: "test")
        let localReport = CLIProxyLocalInstallationReport(
            binaryPath: "/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi",
            configPath: "/opt/homebrew/etc/cliproxyapi.conf",
            usageStatisticsEnabled: true,
            redisUsageQueueRetentionSeconds: 3600
        )
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: ["X-CLIProxyAPI-Version": "6.10.5"], data: Data(#"{"data":[]}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            localInstallationProbe: StaticLocalInstallationProbe(report: localReport),
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()
        let capabilityReport = try #require(snapshot.warnings.first { $0.id == "capability-report" }?.message)
        let redisMissing = try #require(snapshot.missingCapabilities.first { $0.id == "redis-collector" })

        #expect(capabilityReport.contains("local binary: /opt/homebrew/opt/cliproxyapi/bin/cliproxyapi"))
        #expect(capabilityReport.contains("config path: /opt/homebrew/etc/cliproxyapi.conf"))
        #expect(capabilityReport.contains("config usage-statistics-enabled: true"))
        #expect(capabilityReport.contains("config redis usage queue retention: 3600s"))
        #expect(redisMissing.reason == "Local config enables the Redis-compatible usage queue, but no normalized collector snapshot was detected")
    }

    @Test("capability report says Redis collector is disabled when usage stats are off")
    func capabilityReportExplainsDisabledUsageStats() async throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let candidate = CLIProxyUsageEndpointCandidate(baseURL: URL(string: "http://127.0.0.1:8317")!, apiKey: "test-key", source: "test")
        let service = CLIProxyUsageService(
            endpointResolver: StaticResolver(candidates: [candidate]),
            transport: ClosureTransport { request in
                if request.url?.path == "/v1/models" {
                    return CLIProxyUsageHTTPResponse(statusCode: 200, headers: [:], data: Data(#"{"data":[]}"#.utf8))
                }
                return CLIProxyUsageHTTPResponse(statusCode: 404, headers: [:], data: Data())
            },
            localInstallationProbe: StaticLocalInstallationProbe(report: CLIProxyLocalInstallationReport(
                binaryPath: nil,
                configPath: "/opt/homebrew/etc/cliproxyapi.conf",
                usageStatisticsEnabled: false,
                redisUsageQueueRetentionSeconds: nil
            )),
            now: { now }
        )

        let snapshot = await service.fetchUsageSnapshot()
        let redisMissing = try #require(snapshot.missingCapabilities.first { $0.id == "redis-collector" })
        #expect(redisMissing.reason == "Local CLIProxyAPI config disables usage-statistics-enabled")
    }

    @Test("fixture parser preserves multiple accounts and explains absent optional metrics")
    func multiAccountMissingOptionalMetrics() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(
            from: Data(
                """
                {
                  "baseURL": "http://127.0.0.1:8317",
                  "reachable": true,
                  "statsBackend": "usageQueue",
                  "accounts": [
                    {
                      "id": "acct-a",
                      "displayName": "Account A",
                      "providerKind": "codex",
                      "status": "active",
                      "activeSessionCount": 1,
                      "quota": {
                        "limitTokens": 1000,
                        "usedTokens": 250,
                        "resetsAt": "2026-05-10T13:00:00Z"
                      }
                    },
                    {
                      "id": "acct-b",
                      "displayName": "Account B",
                      "providerKind": "claude",
                      "status": "cooling",
                      "activeSessionCount": 2
                    }
                  ],
                  "events": [
                    {
                      "id": "evt-a",
                      "timestamp": "2026-05-10T11:59:30Z",
                      "accountID": "acct-a",
                      "providerKind": "codex",
                      "model": "gpt-5.5",
                      "promptTokens": 100,
                      "completionTokens": 50
                    },
                    {
                      "id": "evt-b",
                      "timestamp": "2026-05-10T11:58:30Z",
                      "accountID": "acct-b",
                      "providerKind": "claude",
                      "model": "claude-opus-4.7",
                      "promptTokens": 80,
                      "completionTokens": 20
                    }
                  ]
                }
                """.utf8
            ),
            now: now
        )

        #expect(snapshot.accounts.map(\.displayName).sorted() == ["Account A", "Account B"])
        #expect(snapshot.accounts.first { $0.displayName == "Account A" }?.capacity?.score == 73)
        #expect(snapshot.models.count == 2)
        #expect(snapshot.sessions.count == 0)
        #expect(snapshot.missingCapabilities.contains { $0.id == "cache-tokens" })
        #expect(snapshot.missingCapabilities.contains { $0.id == "cost-estimates" })
        #expect(snapshot.missingCapabilities.contains { $0.id == "latency" })
        #expect(snapshot.missingCapabilities.contains { $0.id == "time-to-first-token" })
        #expect(snapshot.missingCapabilities.contains { $0.id == "generation-throughput" })
        #expect(snapshot.missingCapabilities.contains { $0.id == "agent-attribution" })
    }

    @Test("fixture parser drops model metadata rows without proven usage metrics")
    func modelMetadataWithoutUsageIsNotRenderedAsZeroUsage() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(
            from: Data(
                """
                {
                  "baseURL": "http://127.0.0.1:8317",
                  "reachable": true,
                  "statsBackend": "usageQueue",
                  "models": [
                    {"model": "gpt-5.5"},
                    {"model": "gpt-5.5-mini", "requestCount": 2, "totalTokens": 300}
                  ],
                  "events": []
                }
                """.utf8
            ),
            now: now
        )

        #expect(snapshot.models.map(\.model) == ["gpt-5.5-mini"])
        #expect(snapshot.models.first?.requestCount == 2)
        #expect(snapshot.models.first?.totalTokens == 300)
    }

    @Test("usage session identifiers join to confirmed agent registry attribution labels")
    func enrichesUsageSessionsWithAgentAttribution() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let usageSnapshot = try CLIProxyUsageFixtureParser.parseSnapshot(
            from: Data(
                """
                {
                  "baseURL": "http://127.0.0.1:8317",
                  "reachable": true,
                  "statsBackend": "usageQueue",
                  "events": [
                    {
                      "id": "evt-a",
                      "timestamp": "2026-05-10T11:59:30Z",
                      "accountID": "acct-a",
                      "providerKind": "codex",
                      "model": "gpt-5.5",
                      "sessionID": "cliproxy-session-1",
                      "promptTokens": 100,
                      "completionTokens": 50
                    }
                  ]
                }
                """.utf8
            ),
            now: now
        )
        let registrySnapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(
                """
                {
                  "sessions": [
                    {
                      "id": "conductor",
                      "role": "conductor",
                      "title": "Roadmap"
                    },
                    {
                      "id": "track-12",
                      "parent_id": "conductor",
                      "role": "orchestrator",
                      "title": "Track 12",
                      "attribution": {
                        "confidence": "confirmed",
                        "request_session_ids": ["cliproxy-session-1"]
                      }
                    }
                  ]
                }
                """.utf8
            ),
            deriveFileRisks: false
        )

        let enriched = CLIProxyUsageAttributionEnricher.enrich(snapshot: usageSnapshot, registrySnapshot: registrySnapshot)
        let session = try #require(enriched.sessions.first)

        #expect(session.attribution?.confidence == .confirmed)
        #expect(session.attribution?.hierarchyLabel == "Roadmap / Track 12")
        #expect(session.attribution?.roleLabel == "Orchestrator")
    }

    @Test("fixture parser derives refill timeline cache score and context bloat from proven inputs")
    func fixtureParserDerivedMetrics() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let snapshot = try CLIProxyUsageFixtureParser.parseSnapshot(
            from: Data(
                """
                {
                  "baseURL": "http://127.0.0.1:8317",
                  "reachable": true,
                  "statsBackend": "usageQueue",
                  "accounts": [
                    {
                      "id": "acct-a",
                      "displayName": "Account A",
                      "providerKind": "codex",
                      "status": "active",
                      "quota": {
                        "limitTokens": 1000,
                        "usedTokens": 250,
                        "resetsAt": "2026-05-10T13:00:00Z"
                      }
                    }
                  ],
                  "events": [
                    {
                      "id": "evt-1",
                      "timestamp": "2026-05-10T11:57:00Z",
                      "accountID": "acct-a",
                      "providerKind": "codex",
                      "model": "gpt-5.5",
                      "sessionID": "cliproxy-session-1",
                      "promptTokens": 100,
                      "completionTokens": 20,
                      "cacheReadTokens": 10,
                      "cacheWriteTokens": 5
                    },
                    {
                      "id": "evt-2",
                      "timestamp": "2026-05-10T11:58:00Z",
                      "accountID": "acct-a",
                      "providerKind": "codex",
                      "model": "gpt-5.5",
                      "sessionID": "cliproxy-session-1",
                      "promptTokens": 200,
                      "completionTokens": 20,
                      "cacheReadTokens": 20,
                      "cacheWriteTokens": 5
                    },
                    {
                      "id": "evt-3",
                      "timestamp": "2026-05-10T11:59:00Z",
                      "accountID": "acct-a",
                      "providerKind": "codex",
                      "model": "gpt-5.5",
                      "sessionID": "cliproxy-session-1",
                      "promptTokens": 450,
                      "completionTokens": 20,
                      "cacheReadTokens": 30,
                      "cacheWriteTokens": 5
                    }
                  ]
                }
                """.utf8
            ),
            now: now
        )

        #expect(snapshot.refillTimeline.first?.accountDisplayName == "Account A")
        #expect(snapshot.refillTimeline.first?.remainingTokens == 750)
        #expect(abs((snapshot.models.first?.cachePreservationScore ?? 0) - (75.0 / 750.0)) < 0.0001)
        let signal = try #require(snapshot.sessions.first?.contextBloatSignal)
        #expect(signal.isBloating)
        #expect(signal.deltaPromptTokens == 350)
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

    @Test("codex config detection accepts experimental bearer token for local endpoints")
    func codexConfigDetectionUsesExperimentalBearerToken() throws {
        let config = Data(
            """
            [model_providers.CLIProxyAPI]
            base_url = "http://127.0.0.1:8317/v1"
            experimental_bearer_token = "codex-local-bearer"
            """.utf8
        )

        let candidate = try #require(CLIProxyUsageEndpointResolver.parseCodexConfig(data: config).first)
        #expect(candidate.baseURL.absoluteString == "http://127.0.0.1:8317")
        #expect(candidate.apiKey == "codex-local-bearer")
    }

    @Test("endpoint resolver applies local environment API key to CLIProxyAPI URL candidates")
    func endpointResolverUsesLocalEnvironmentAPIKey() throws {
        let resolver = CLIProxyUsageEndpointResolver(
            env: [
                "CLIPROXYAPI_URL": "http://localhost:8317/v1/",
                "CLIPROXYAPI_API_KEY": " local-env-key ",
            ],
            homeDirectory: "/tmp/muxy-empty-home",
            fileExists: { _ in false },
            dataReader: { _ in Data() }
        )

        let candidates = resolver.endpointCandidates()
        let candidate = try #require(candidates.first { $0.baseURL.absoluteString == "http://localhost:8317" })
        #expect(candidate.apiKey == "local-env-key")
    }

    @Test("endpoint resolver prefers later credentials over unauthenticated duplicate base")
    func endpointResolverPrefersCredentialsForDuplicateBase() throws {
        let configPath = "/tmp/muxy-codex/config.toml"
        let resolver = CLIProxyUsageEndpointResolver(
            env: [
                "CLIPROXYAPI_BASE_URL": "http://127.0.0.1:8317/v1",
                "CODEX_HOME": "/tmp/muxy-codex",
            ],
            homeDirectory: "/tmp/muxy-home",
            fileExists: { $0 == configPath },
            dataReader: { path in
                #expect(path == configPath)
                return Data(
                    """
                    [model_providers.cliproxy]
                    base_url = "http://127.0.0.1:8317/v1"
                    api_key = "codex-local-key"
                    """.utf8
                )
            }
        )

        let candidates = resolver.endpointCandidates()
        let candidate = try #require(candidates.first { $0.baseURL.absoluteString == "http://127.0.0.1:8317" })
        #expect(candidate.apiKey == "codex-local-key")
        #expect(candidate.source == "codex-config")
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
                  "lastUsedAt": "2026-05-10T11:58:00Z",
                  "recentFailure": {"occurredAt": "2026-05-10T11:56:00Z", "message": "rate_limit token secret-token-123456789"},
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
                  "completionTokens": 50,
                  "cacheReadTokens": 20,
                  "costEstimateUSD": 0.01
                },
                {
                  "id": "evt-2",
                  "timestamp": "2026-05-10T11:57:00Z",
                  "accountID": "acct-local",
                  "providerKind": "codex",
                  "model": "gpt-5.5",
                  "sessionID": "session-local",
                  "promptTokens": 200,
                  "completionTokens": 100,
                  "cacheWriteTokens": 10,
                  "costEstimateUSD": 0.02
                }
              ]
            }
            """.utf8
        )
    }

    private static func usageQueueData() -> Data {
        Data(
            """
            [
              {
                "timestamp": "2026-05-10T11:59:30Z",
                "latency_ms": 1200,
                "source": "paul@example.com",
                "auth_index": "paul@example.com",
                "tokens": {
                  "input_tokens": 100,
                  "output_tokens": 20,
                  "reasoning_tokens": 5,
                  "cached_tokens": 40,
                  "total_tokens": 125
                },
                "failed": false,
                "fail": {"status_code": 200, "body": ""},
                "provider": "codex",
                "model": "gpt-5.5",
                "alias": "gpt-5.5",
                "endpoint": "/v1/responses",
                "auth_type": "oauth",
                "api_key": "sk-proj-1234567890abcdefXYZ",
                "request_id": "req_secret_token_123456789"
              }
            ]
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

private struct StaticLocalInstallationProbe: CLIProxyLocalInstallationProbing {
    let report: CLIProxyLocalInstallationReport

    func installationReport() -> CLIProxyLocalInstallationReport {
        report
    }
}

private final class InMemoryCLIProxyUsageEventStore: CLIProxyUsageEventPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var eventsByID: [String: CLIProxyUsageEvent] = [:]

    func append(_ events: [CLIProxyUsageEvent], pruningBefore cutoff: Date?) throws {
        lock.lock()
        defer { lock.unlock() }
        if let cutoff {
            eventsByID = eventsByID.filter { $0.value.timestamp >= cutoff }
        }
        for event in events {
            eventsByID[event.id] = event
        }
    }

    func loadEvents(since cutoff: Date?) throws -> [CLIProxyUsageEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventsByID.values
            .filter { event in
                guard let cutoff else { return true }
                return event.timestamp >= cutoff
            }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { $0.url?.path ?? "" }
    }

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}
