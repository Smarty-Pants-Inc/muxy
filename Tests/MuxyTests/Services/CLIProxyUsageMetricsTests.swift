import Foundation
import Testing

@testable import Muxy

@Suite("CLIProxyUsageMetrics")
struct CLIProxyUsageMetricsTests {
    @Test("calculates token velocity over rolling windows")
    func rollingWindowVelocity() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let events = [
            Self.event(id: "event-1", timestamp: now.addingTimeInterval(-30), prompt: 100, completion: 50),
            Self.event(id: "event-2", timestamp: now.addingTimeInterval(-120), prompt: 200, completion: 100),
            Self.event(id: "event-3", timestamp: now.addingTimeInterval(-600), prompt: 300, completion: 100),
            Self.event(id: "event-4", timestamp: now.addingTimeInterval(-1_800), prompt: 1_000, completion: 500, error: "rate_limit"),
            Self.event(id: "event-5", timestamp: now.addingTimeInterval(-7_200), prompt: 9_999, completion: 1),
        ]

        let windows = CLIProxyUsageMetricsCalculator.rollingWindows(events: events, now: now)
        let velocities = CLIProxyUsageMetricsCalculator.velocities(for: windows)

        let oneMinute = try #require(velocities.first { $0.id == "1m" })
        #expect(oneMinute.totalTokens == 150)
        #expect(oneMinute.requestCount == 1)
        #expect(abs(oneMinute.tokensPerMinute - 150) < 0.001)

        let fiveMinutes = try #require(velocities.first { $0.id == "5m" })
        #expect(fiveMinutes.totalTokens == 450)
        #expect(fiveMinutes.requestCount == 2)
        #expect(abs(fiveMinutes.tokensPerMinute - 90) < 0.001)
        #expect(abs(fiveMinutes.requestsPerMinute - 0.4) < 0.001)

        let fifteenMinutes = try #require(velocities.first { $0.id == "15m" })
        #expect(fifteenMinutes.totalTokens == 850)
        #expect(abs(fifteenMinutes.tokensPerMinute - 56.666) < 0.01)

        let hour = try #require(windows.first { $0.id == "1h" })
        #expect(hour.totalTokens == 2_350)
        #expect(hour.errorCount == 1)
    }

    @Test("returns missing runway and capacity reasons when data is absent")
    func missingDataBehavior() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let account = CLIProxyAccountUsage(
            id: "acct-local",
            displayName: "acct-local",
            providerKind: "codex",
            status: .active,
            activeSessionCount: nil,
            quota: nil,
            lastUsedAt: nil,
            recentFailure: nil,
            recent: [],
            capacity: nil
        )

        let estimate = CLIProxyUsageMetricsCalculator.capacity(account: account, currentVelocity: nil, now: now)
        #expect(estimate.score == nil)
        #expect(estimate.reason == "Quota window unavailable")
        #expect(estimate.runway.reason == "Quota window unavailable")
    }

    @Test("calculates ETA and capacity when quota exists")
    func capacityAndETA() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let quota = CLIProxyQuotaWindow(
            startsAt: now.addingTimeInterval(-3_600),
            resetsAt: now.addingTimeInterval(3_600),
            limitTokens: 10_000,
            usedTokens: 4_000
        )
        let window = CLIProxyUsageWindow(
            id: "5m",
            label: "5m",
            startsAt: now.addingTimeInterval(-300),
            endsAt: now,
            promptTokens: 3_000,
            completionTokens: 3_000,
            totalTokens: 6_000,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            costEstimateUSD: nil,
            requestCount: 3,
            errorCount: 0
        )
        let velocity = try #require(CLIProxyUsageMetricsCalculator.velocities(for: [window]).first)
        let account = CLIProxyAccountUsage(
            id: "acct-local",
            displayName: "acct-local",
            providerKind: "codex",
            status: .active,
            activeSessionCount: 0,
            quota: quota,
            lastUsedAt: nil,
            recentFailure: nil,
            recent: [window],
            capacity: nil
        )

        let estimate = CLIProxyUsageMetricsCalculator.capacity(account: account, currentVelocity: velocity, now: now)
        #expect(estimate.score == 60)
        #expect(abs((estimate.runway.minutesUntilExhaustion ?? 0) - 5) < 0.001)
        #expect(estimate.runway.exhaustionDate == now.addingTimeInterval(300))
    }


    @Test("aggregates optional metrics only when inputs exist")
    func optionalMetricAggregation() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let events = [
            Self.event(
                id: "event-1",
                timestamp: now.addingTimeInterval(-30),
                prompt: 100,
                completion: 50,
                cacheRead: 25,
                cacheWrite: 5,
                latency: 1_000,
                timeToFirstToken: 200,
                generationDuration: 2_000,
                cost: 0.012
            ),
            Self.event(
                id: "event-2",
                timestamp: now.addingTimeInterval(-90),
                prompt: 200,
                completion: 100,
                cacheRead: nil,
                cacheWrite: 10,
                latency: 2_000,
                timeToFirstToken: 100,
                generationDuration: 4_000,
                cost: 0.018
            ),
        ]

        let hour = try #require(CLIProxyUsageMetricsCalculator.rollingWindows(events: events, now: now).first { $0.id == "1h" })
        #expect(hour.cacheReadTokens == 25)
        #expect(hour.cacheWriteTokens == 15)
        #expect(abs((hour.costEstimateUSD ?? 0) - 0.03) < 0.0001)

        let model = try #require(CLIProxyUsageMetricsCalculator.modelUsage(events: events).first)
        #expect(model.cacheReadTokens == 25)
        #expect(model.cacheWriteTokens == 15)
        #expect(abs((model.costEstimateUSD ?? 0) - 0.03) < 0.0001)
        #expect(model.averageLatencyMS == 1_500)
        #expect(model.averageTimeToFirstTokenMS == 150)
        #expect(abs((model.generationTokensPerSecond ?? 0) - 25) < 0.0001)
        #expect(abs((model.cachePreservationScore ?? 0) - (40.0 / 300.0)) < 0.0001)
    }

    @Test("cache preservation score requires prompt and cache read/write inputs")
    func cachePreservationScoreCapabilityGate() throws {
        let modelWithoutWrite = CLIProxyModelUsage(
            id: "gpt-5.5",
            model: "gpt-5.5",
            promptTokens: 100,
            completionTokens: 20,
            totalTokens: 120,
            requestCount: 1,
            errorCount: 0,
            averageLatencyMS: nil,
            cacheReadTokens: 40,
            cacheWriteTokens: nil,
            costEstimateUSD: nil
        )
        let windowWithoutPrompt = CLIProxyUsageWindow(
            id: "1m",
            label: "1m",
            startsAt: try #require(Self.date("2026-05-10T11:59:00Z")),
            endsAt: try #require(Self.date("2026-05-10T12:00:00Z")),
            promptTokens: 0,
            completionTokens: 20,
            totalTokens: 20,
            cacheReadTokens: 40,
            cacheWriteTokens: 10,
            costEstimateUSD: nil,
            requestCount: 1,
            errorCount: 0
        )

        #expect(modelWithoutWrite.cachePreservationScore == nil)
        #expect(windowWithoutPrompt.cachePreservationScore == nil)
    }

    @Test("aggregates hot sessions from request session identifiers")
    func sessionUsageAggregation() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let events = [
            Self.event(id: "event-1", timestamp: now.addingTimeInterval(-30), prompt: 100, completion: 50, sessionID: "session-a"),
            Self.event(id: "event-2", timestamp: now.addingTimeInterval(-20), prompt: 200, completion: 100, sessionID: "session-a"),
            Self.event(id: "event-3", timestamp: now.addingTimeInterval(-10), prompt: 25, completion: 25, error: "rate_limit", sessionID: "session-b"),
            Self.event(id: "event-4", timestamp: now.addingTimeInterval(-5), prompt: 999, completion: 1, sessionID: nil),
        ]

        let sessions = CLIProxyUsageMetricsCalculator.sessionUsage(events: events)

        #expect(sessions.map { $0.id } == ["session-a", "session-b"])
        let sessionA = try #require(sessions.first)
        #expect(sessionA.totalTokens == 450)
        #expect(sessionA.promptTokens == 300)
        #expect(sessionA.completionTokens == 150)
        #expect(sessionA.requestCount == 2)
        #expect(sessionA.modelNames == ["gpt-5.5"])
        let sessionB = try #require(sessions.first { $0.id == "session-b" })
        #expect(sessionB.errorCount == 1)
    }

    @Test("detects context bloat from per-session prompt-token trend")
    func contextBloatTrend() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let events = [
            Self.event(id: "event-1", timestamp: now.addingTimeInterval(-180), prompt: 100, completion: 20, sessionID: "session-a"),
            Self.event(id: "event-2", timestamp: now.addingTimeInterval(-120), prompt: 200, completion: 20, sessionID: "session-a"),
            Self.event(id: "event-3", timestamp: now.addingTimeInterval(-60), prompt: 450, completion: 20, sessionID: "session-a"),
            Self.event(id: "event-4", timestamp: now.addingTimeInterval(-30), prompt: 300, completion: 20, sessionID: "session-b"),
            Self.event(id: "event-5", timestamp: now.addingTimeInterval(-20), prompt: 320, completion: 20, sessionID: "session-b"),
        ]

        let sessions = CLIProxyUsageMetricsCalculator.sessionUsage(events: events)
        let bloated = try #require(sessions.first { $0.id == "session-a" }?.contextBloatSignal)

        #expect(bloated.sampleCount == 3)
        #expect(bloated.firstAveragePromptTokens == 100)
        #expect(bloated.latestAveragePromptTokens == 450)
        #expect(bloated.deltaPromptTokens == 350)
        #expect(bloated.isBloating)
        #expect(sessions.first { $0.id == "session-b" }?.contextBloatSignal == nil)
    }

    @Test("derives refill timeline from quota reset windows")
    func refillTimeline() throws {
        let now = try #require(Self.date("2026-05-10T12:00:00Z"))
        let later = try #require(Self.date("2026-05-10T14:00:00Z"))
        let sooner = try #require(Self.date("2026-05-10T13:00:00Z"))
        let snapshot = CLIProxyUsageSnapshot(
            fetchedAt: now,
            baseURL: try #require(URL(string: "http://127.0.0.1:8317")),
            isProxyReachable: true,
            version: nil,
            statsBackend: .usageQueue,
            accounts: [
                CLIProxyAccountUsage(
                    id: "acct-later",
                    displayName: "Account Later",
                    providerKind: "codex",
                    status: .active,
                    activeSessionCount: nil,
                    quota: CLIProxyQuotaWindow(startsAt: nil, resetsAt: later, limitTokens: 10_000, usedTokens: 9_000),
                    lastUsedAt: nil,
                    recentFailure: nil,
                    recent: [],
                    capacity: nil
                ),
                CLIProxyAccountUsage(
                    id: "acct-sooner",
                    displayName: "Account Soon",
                    providerKind: "claude",
                    status: .cooling,
                    activeSessionCount: nil,
                    quota: CLIProxyQuotaWindow(startsAt: nil, resetsAt: sooner, limitTokens: 5_000, usedTokens: 1_000),
                    lastUsedAt: nil,
                    recentFailure: nil,
                    recent: [],
                    capacity: nil
                ),
                CLIProxyAccountUsage(
                    id: "acct-no-quota",
                    displayName: "No quota",
                    providerKind: "unknown",
                    status: .unknown,
                    activeSessionCount: nil,
                    quota: nil,
                    lastUsedAt: nil,
                    recentFailure: nil,
                    recent: [],
                    capacity: nil
                ),
            ],
            models: [],
            windows: [],
            velocities: [],
            warnings: [],
            missingCapabilities: []
        )

        let refills = snapshot.refillTimeline
        #expect(refills.map(\.accountID) == ["acct-sooner", "acct-later"])
        #expect(refills.first?.remainingTokens == 4_000)
        #expect(refills.first?.limitTokens == 5_000)
    }

    private static func event(
        id: String,
        timestamp: Date,
        prompt: Int,
        completion: Int,
        error: String? = nil,
        cacheRead: Int? = nil,
        cacheWrite: Int? = nil,
        latency: Int? = nil,
        timeToFirstToken: Int? = nil,
        generationDuration: Int? = nil,
        cost: Double? = nil,
        sessionID: String? = "session-local"
    ) -> CLIProxyUsageEvent {
        CLIProxyUsageEvent(
            id: id,
            timestamp: timestamp,
            accountID: "acct-local",
            accountDisplayName: "acct-local",
            providerKind: "codex",
            model: "gpt-5.5",
            sessionID: sessionID,
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: nil,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            latencyMS: latency,
            timeToFirstTokenMS: timeToFirstToken,
            generationDurationMS: generationDuration,
            errorCode: error,
            costEstimateUSD: cost
        )
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
