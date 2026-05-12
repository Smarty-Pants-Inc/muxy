import Foundation
import Testing

@testable import Muxy

@Suite("CLIProxyUsageSection")
struct CLIProxyUsageSectionTests {
    @Test("history unavailable text uses explicit missing capability reason")
    func historyUnavailableText() throws {
        let snapshot = CLIProxyUsageSnapshot(
            fetchedAt: try #require(Self.date("2026-05-10T12:00:00Z")),
            baseURL: try #require(URL(string: "http://127.0.0.1:8317")),
            isProxyReachable: true,
            version: "CLIProxyAPI Version: 6.10.5",
            statsBackend: .proxyOnly,
            accounts: [],
            models: [],
            windows: [],
            velocities: [],
            warnings: [],
            missingCapabilities: [
                CLIProxyMissingCapability(
                    id: "usage-history",
                    capability: "Usage history",
                    reason: "No Redis-queue collector, app-owned SQLite snapshot endpoint, dashboard, or built-in stats source was detected"
                ),
            ]
        )

        #expect(CLIProxyUsageFormatter.historyUnavailableText(snapshot: snapshot).contains("No Redis-queue collector"))
    }

    @Test("optional metric unavailable text uses explicit missing capability reason")
    func optionalMetricUnavailableText() throws {
        let snapshot = CLIProxyUsageSnapshot(
            fetchedAt: try #require(Self.date("2026-05-10T12:00:00Z")),
            baseURL: try #require(URL(string: "http://127.0.0.1:8317")),
            isProxyReachable: true,
            version: nil,
            statsBackend: .usageQueue,
            accounts: [],
            models: [],
            windows: [],
            velocities: [],
            warnings: [],
            missingCapabilities: [
                CLIProxyMissingCapability(
                    id: "cache-tokens",
                    capability: "Cache token metrics",
                    reason: "Detected stats do not include cache read/write token counts"
                ),
            ]
        )

        #expect(CLIProxyUsageFormatter.missingCapabilityText(snapshot: snapshot, id: "cache-tokens")?.contains("cache read/write") == true)
        #expect(CLIProxyUsageFormatter.missingCapabilityText(snapshot: snapshot, id: "latency") == nil)
    }

    @Test("formatter redacts sensitive values")
    func redactsSensitiveValues() {
        let redacted = CLIProxyUsageFormatter.redacted(
            "Authorization=secret-token-123456789 user@example.com sk-1234567890abcdefXYZ"
        )

        #expect(!redacted.contains("secret-token"))
        #expect(!redacted.contains("user@example.com"))
        #expect(!redacted.contains("sk-1234567890abcdefXYZ"))
        #expect(redacted.contains("[REDACTED"))
    }

    @Test("formatter does not redact normal words that resemble short key fragments")
    func avoidsOverRedactingNormalWords() {
        let redacted = CLIProxyUsageFormatter.redacted("skill skeptic sk-test status ok")

        #expect(redacted == "skill skeptic sk-test status ok")
    }

    @Test("formatter exposes compact velocity and status labels")
    func velocityAndStatusFormatting() {
        #expect(CLIProxyUsageFormatter.tokensPerMinute(12.4) == "12.4 tok/min")
        #expect(CLIProxyUsageFormatter.tokensPerSecond(4.2) == "4.2 tok/s")
        #expect(CLIProxyUsageFormatter.requestsPerMinute(2) == "2.0 req/min")
        #expect(CLIProxyUsageFormatter.statusLabel(.cooling) == "cooling")
    }

    @Test("formatter exposes safe textual velocity sparkline")
    func velocitySparklineFormatting() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let windows = [
            CLIProxyUsageWindow(
                id: "1m",
                label: "1m",
                startsAt: now.addingTimeInterval(-60),
                endsAt: now,
                promptTokens: 90,
                completionTokens: 30,
                totalTokens: 120,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                costEstimateUSD: nil,
                requestCount: 1,
                errorCount: 0
            ),
            CLIProxyUsageWindow(
                id: "5m",
                label: "5m",
                startsAt: now.addingTimeInterval(-300),
                endsAt: now,
                promptTokens: 200,
                completionTokens: 100,
                totalTokens: 300,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                costEstimateUSD: nil,
                requestCount: 2,
                errorCount: 0
            ),
        ]

        let sparkline = try #require(CLIProxyUsageFormatter.velocitySparkline(CLIProxyUsageMetricsCalculator.velocities(for: windows)))
        #expect(sparkline == "1m[########] 5m[####....]")
    }

    @Test("velocity sparkline is unavailable instead of drawing fake zero-token bars")
    func velocitySparklineCapabilityGate() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let windows = [
            CLIProxyUsageWindow(
                id: "1m",
                label: "1m",
                startsAt: now.addingTimeInterval(-60),
                endsAt: now,
                promptTokens: 0,
                completionTokens: 0,
                totalTokens: 0,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                costEstimateUSD: nil,
                requestCount: 1,
                errorCount: 0
            ),
        ]

        #expect(CLIProxyUsageFormatter.velocitySparkline(CLIProxyUsageMetricsCalculator.velocities(for: windows)) == nil)
    }

    @Test("formatter exposes refill cache and context-bloat text from proven metrics")
    func derivedMetricFormatting() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let refill = CLIProxyRefillEvent(
            id: "acct-a-1",
            accountID: "acct-a",
            accountDisplayName: "Account A",
            providerKind: "codex",
            resetsAt: now.addingTimeInterval(90 * 60),
            remainingTokens: 750,
            limitTokens: 1_000
        )
        let signal = CLIProxyContextBloatSignal(
            sampleCount: 3,
            firstAveragePromptTokens: 100,
            latestAveragePromptTokens: 450,
            deltaPromptTokens: 350,
            percentChange: 350
        )

        #expect(CLIProxyUsageFormatter.refillLine(refill, now: now) == "in 1h 30m · 750/1000 tokens left")
        #expect(CLIProxyUsageFormatter.cachePreservationScore(0.125) == "12.5% cache preserved")
        #expect(CLIProxyUsageFormatter.contextBloat(signal) == "Context bloat: +350 prompt avg (+350%) over 3 requests")
    }

    @Test("accounts detail does not render unknown account status as zero active")
    func accountsDetailExplainsUnknownStatus() {
        let unknown = Self.account(id: "unknown", status: .unknown)
        let active = Self.account(id: "active", status: .active)

        #expect(CLIProxyUsageFormatter.accountsDetail([unknown]) == "status unknown")
        #expect(CLIProxyUsageFormatter.accountsDetail([active, unknown]) == "1 active, 1 unknown")
    }

    @Test("formatter labels confirmed and suggested attribution")
    func attributionFormatting() {
        let confirmed = CLIProxySessionAttribution(
            displayLabel: "Track 12",
            hierarchyLabel: "Roadmap / Track 12",
            roleLabel: "Orchestrator",
            confidence: .confirmed
        )
        let suggested = CLIProxySessionAttribution(
            displayLabel: "Track 13",
            hierarchyLabel: "Roadmap / Track 13",
            roleLabel: "Orchestrator",
            confidence: .suggested
        )

        #expect(CLIProxyUsageFormatter.attributionLabel(confirmed) == "Attributed: Roadmap / Track 12")
        #expect(CLIProxyUsageFormatter.attributionLabel(suggested) == "Suggested: Roadmap / Track 13")
    }

    @Test("capability report remains addressable even when other warnings exist")
    func capabilityReportText() throws {
        let snapshot = CLIProxyUsageSnapshot(
            fetchedAt: try #require(Self.date("2026-05-10T12:00:00Z")),
            baseURL: try #require(URL(string: "http://127.0.0.1:8317")),
            isProxyReachable: true,
            version: nil,
            statsBackend: .proxyOnly,
            accounts: [],
            models: [],
            windows: [],
            velocities: [],
            warnings: [
                CLIProxyUsageWarning(id: "first", severity: .warning, message: "first warning"),
                CLIProxyUsageWarning(id: "capability-report", severity: .info, message: "stats surfaces: /v0/usage/snapshot: HTTP 404"),
            ],
            missingCapabilities: []
        )

        #expect(CLIProxyUsageFormatter.capabilityReportText(snapshot: snapshot)?.contains("stats surfaces") == true)
    }

    @Test("runway explains unavailable ETA instead of zeroing it")
    func runwayMissingReason() {
        let estimate = CLIProxyRunwayEstimate(
            minutesUntilExhaustion: nil,
            exhaustionDate: nil,
            reason: "Token velocity unavailable"
        )

        #expect(CLIProxyUsageFormatter.runway(estimate) == "Token velocity unavailable")
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func account(id: String, status: CLIProxyAccountStatus) -> CLIProxyAccountUsage {
        CLIProxyAccountUsage(
            id: id,
            displayName: id,
            providerKind: "codex",
            status: status,
            activeSessionCount: nil,
            quota: nil,
            lastUsedAt: nil,
            recentFailure: nil,
            recent: [],
            capacity: nil
        )
    }
}
