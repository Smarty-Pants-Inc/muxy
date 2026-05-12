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
            let timeToFirstTokenValues = events.compactMap(\.countedTimeToFirstTokenMS)
            let averageTimeToFirstToken: Double? = if timeToFirstTokenValues.isEmpty {
                nil
            } else {
                Double(timeToFirstTokenValues.reduce(0, +)) / Double(timeToFirstTokenValues.count)
            }
            let generationThroughput = generationTokensPerSecond(events: events)
            return CLIProxyModelUsage(
                id: model,
                model: CLIProxyUsageRedactor.redact(model),
                promptTokens: events.reduce(0) { $0 + $1.countedPromptTokens },
                completionTokens: events.reduce(0) { $0 + $1.countedCompletionTokens },
                totalTokens: events.reduce(0) { $0 + ($1.countedTotalTokens ?? 0) },
                requestCount: events.count,
                errorCount: events.count(where: { $0.errorCode != nil }),
                averageLatencyMS: averageLatency,
                averageTimeToFirstTokenMS: averageTimeToFirstToken,
                generationTokensPerSecond: generationThroughput,
                cacheReadTokens: sumOptional(events.compactMap(\.cacheReadTokens)),
                cacheWriteTokens: sumOptional(events.compactMap(\.cacheWriteTokens)),
                costEstimateUSD: sumOptional(events.compactMap(\.countedCostEstimateUSD))
            )
        }
        .sorted { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
    }

    static func sessionUsage(events: [CLIProxyUsageEvent]) -> [CLIProxySessionUsage] {
        let grouped = Dictionary(grouping: events.compactMap { event -> (String, CLIProxyUsageEvent)? in
            guard let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionID.isEmpty
            else { return nil }
            return (sessionID, event)
        }, by: \.0).mapValues { $0.map(\.1) }

        return grouped.map { sessionID, events in
            let models = Array(Set(events.compactMap(\.model))).sorted()
            return CLIProxySessionUsage(
                id: sessionID,
                displayName: sessionID,
                promptTokens: events.reduce(0) { $0 + $1.countedPromptTokens },
                completionTokens: events.reduce(0) { $0 + $1.countedCompletionTokens },
                totalTokens: events.reduce(0) { $0 + ($1.countedTotalTokens ?? 0) },
                requestCount: events.count,
                errorCount: events.count(where: { $0.errorCode != nil }),
                modelNames: models,
                lastUsedAt: events.map(\.timestamp).max(),
                contextBloatSignal: contextBloatSignal(events: events)
            )
        }
        .sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
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

    private static func sumOptional(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + max(0, $1) }
    }

    private static func sumOptional(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + max(0, $1) }
    }

    private static func generationTokensPerSecond(events: [CLIProxyUsageEvent]) -> Double? {
        let pairs = events.compactMap { event -> (tokens: Int, seconds: Double)? in
            guard let duration = event.countedGenerationDurationMS else { return nil }
            return (event.countedCompletionTokens, Double(duration) / 1000)
        }
        let totalSeconds = pairs.reduce(0) { $0 + $1.seconds }
        guard totalSeconds > 0 else { return nil }
        let totalTokens = pairs.reduce(0) { $0 + max(0, $1.tokens) }
        return Double(totalTokens) / totalSeconds
    }

    private static func contextBloatSignal(events: [CLIProxyUsageEvent]) -> CLIProxyContextBloatSignal? {
        let samples = events
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
            .compactMap { event -> Int? in
                guard event.promptTokens != nil else { return nil }
                return event.countedPromptTokens
            }
        guard samples.count >= 3 else { return nil }

        let windowSize = max(1, samples.count / 2)
        let firstAverage = average(samples.prefix(windowSize))
        let latestAverage = average(samples.suffix(windowSize))
        let delta = latestAverage - firstAverage
        let percentChange = firstAverage > 0 ? Double(delta) / Double(firstAverage) * 100 : nil
        return CLIProxyContextBloatSignal(
            sampleCount: samples.count,
            firstAveragePromptTokens: firstAverage,
            latestAveragePromptTokens: latestAverage,
            deltaPromptTokens: delta,
            percentChange: percentChange
        )
    }

    private static func average(_ values: some Sequence<Int>) -> Int {
        let collected = Array(values)
        guard !collected.isEmpty else { return 0 }
        return Int((Double(collected.reduce(0, +)) / Double(collected.count)).rounded())
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
            cacheReadTokens: sumOptional(cacheReads),
            cacheWriteTokens: sumOptional(cacheWrites),
            costEstimateUSD: sumOptional(events.compactMap(\.countedCostEstimateUSD)),
            requestCount: events.count,
            errorCount: events.count(where: { $0.errorCode != nil })
        )
    }
}
