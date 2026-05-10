import Foundation

enum CLIProxyUsageWindowPreset: CaseIterable, Equatable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    var id: String {
        switch self {
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .oneHour: "1h"
        }
    }

    var label: String { id }

    var duration: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .oneHour: 3600
        }
    }
}

enum CLIProxyUsageMetricsCalculator {
    static func rollingWindows(
        events: [CLIProxyUsageEvent],
        now: Date,
        presets: [CLIProxyUsageWindowPreset] = CLIProxyUsageWindowPreset.allCases
    ) -> [CLIProxyUsageWindow] {
        presets.map { preset in
            let startsAt = now.addingTimeInterval(-preset.duration)
            let windowEvents = events.filter { event in
                event.timestamp >= startsAt && event.timestamp <= now
            }
            return window(for: windowEvents, preset: preset, startsAt: startsAt, endsAt: now)
        }
    }

    static func velocities(for windows: [CLIProxyUsageWindow]) -> [CLIProxyUsageVelocity] {
        windows.map { window in
            let duration = max((window.endsAt ?? Date()).timeIntervalSince(window.startsAt), 1)
            let minutes = max(duration / 60, 1 / 60)
            return CLIProxyUsageVelocity(
                id: window.id,
                label: window.label,
                windowDuration: duration,
                totalTokens: window.totalTokens,
                requestCount: window.requestCount,
                tokensPerMinute: Double(window.totalTokens) / minutes,
                requestsPerMinute: Double(window.requestCount) / minutes
            )
        }
    }

    static func modelUsage(events: [CLIProxyUsageEvent]) -> [CLIProxyModelUsage] {
        let grouped = Dictionary(grouping: events) { event in
            if let model = event.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                return model
            }
            return "unknown"
        }
        return grouped.map { model, events in
            let latencyValues = events.compactMap(\.latencyMS)
            let averageLatency: Double? = if latencyValues.isEmpty {
                nil
            } else {
                Double(latencyValues.reduce(0, +)) / Double(latencyValues.count)
            }
            return CLIProxyModelUsage(
                id: model,
                model: CLIProxyUsageRedactor.redact(model),
                promptTokens: events.reduce(0) { $0 + $1.countedPromptTokens },
                completionTokens: events.reduce(0) { $0 + $1.countedCompletionTokens },
                totalTokens: events.reduce(0) { $0 + ($1.countedTotalTokens ?? 0) },
                requestCount: events.count,
                errorCount: events.count(where: { $0.errorCode != nil }),
                averageLatencyMS: averageLatency
            )
        }
        .sorted { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
    }

    static func runway(quota: CLIProxyQuotaWindow?, velocity: CLIProxyUsageVelocity?, now: Date) -> CLIProxyRunwayEstimate {
        guard let quota else {
            return CLIProxyRunwayEstimate(minutesUntilExhaustion: nil, exhaustionDate: nil, reason: "Quota window unavailable")
        }
        guard quota.remainingTokens > 0 else {
            return CLIProxyRunwayEstimate(minutesUntilExhaustion: 0, exhaustionDate: now, reason: nil)
        }
        guard let velocity, velocity.tokensPerMinute > 0 else {
            return CLIProxyRunwayEstimate(minutesUntilExhaustion: nil, exhaustionDate: nil, reason: "Token velocity unavailable")
        }
        let minutes = Double(quota.remainingTokens) / velocity.tokensPerMinute
        return CLIProxyRunwayEstimate(
            minutesUntilExhaustion: minutes,
            exhaustionDate: now.addingTimeInterval(minutes * 60),
            reason: nil
        )
    }

    static func capacity(account: CLIProxyAccountUsage, currentVelocity: CLIProxyUsageVelocity?, now: Date) -> CLIProxyCapacityEstimate {
        guard let quota = account.quota, let usedPercent = quota.usedPercent else {
            return CLIProxyCapacityEstimate(
                accountID: account.id,
                score: nil,
                runway: runway(quota: account.quota, velocity: currentVelocity, now: now),
                reason: "Quota window unavailable"
            )
        }

        let statusMultiplier: Double = switch account.status {
        case .active,
             .idle,
             .unknown: 1
        case .cooling: 0.25
        case .error: 0.4
        case .disabled,
             .exhausted: 0
        }
        let sessionPenalty = min(Double(account.activeSessionCount ?? 0) * 2, 20)
        let score = max(0, min(100, (100 - usedPercent) * statusMultiplier - sessionPenalty))
        return CLIProxyCapacityEstimate(
            accountID: account.id,
            score: score,
            runway: runway(quota: quota, velocity: currentVelocity, now: now),
            reason: nil
        )
    }

    private static func window(
        for events: [CLIProxyUsageEvent],
        preset: CLIProxyUsageWindowPreset,
        startsAt: Date,
        endsAt: Date
    ) -> CLIProxyUsageWindow {
        let cacheReads = events.compactMap(\.cacheReadTokens)
        let cacheWrites = events.compactMap(\.cacheWriteTokens)
        return CLIProxyUsageWindow(
            id: preset.id,
            label: preset.label,
            startsAt: startsAt,
            endsAt: endsAt,
            promptTokens: events.reduce(0) { $0 + $1.countedPromptTokens },
            completionTokens: events.reduce(0) { $0 + $1.countedCompletionTokens },
            totalTokens: events.reduce(0) { $0 + ($1.countedTotalTokens ?? 0) },
            cacheReadTokens: cacheReads.isEmpty ? nil : cacheReads.reduce(0) { $0 + max(0, $1) },
            cacheWriteTokens: cacheWrites.isEmpty ? nil : cacheWrites.reduce(0) { $0 + max(0, $1) },
            requestCount: events.count,
            errorCount: events.count(where: { $0.errorCode != nil })
        )
    }
}
