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
            recent: [window],
            capacity: nil
        )

        let estimate = CLIProxyUsageMetricsCalculator.capacity(account: account, currentVelocity: velocity, now: now)
        #expect(estimate.score == 60)
        #expect(abs((estimate.runway.minutesUntilExhaustion ?? 0) - 5) < 0.001)
        #expect(estimate.runway.exhaustionDate == now.addingTimeInterval(300))
    }

    private static func event(
        id: String,
        timestamp: Date,
        prompt: Int,
        completion: Int,
        error: String? = nil
    ) -> CLIProxyUsageEvent {
        CLIProxyUsageEvent(
            id: id,
            timestamp: timestamp,
            accountID: "acct-local",
            accountDisplayName: "acct-local",
            providerKind: "codex",
            model: "gpt-5.5",
            sessionID: "session-local",
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            latencyMS: nil,
            errorCode: error
        )
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
