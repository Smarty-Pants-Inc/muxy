import Foundation

enum CLIProxyUsageFixtureParserError: Error {
    case invalidBaseURL
}

enum CLIProxyUsageFixtureParser {
    static func parseSnapshot(from data: Data, now: Date, fallbackBaseURL: URL? = nil) throws -> CLIProxyUsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDate(from:))
        let fixture = try decoder.decode(Fixture.self, from: data)
        let baseURL = fixture.baseURL ?? fallbackBaseURL ?? URL(string: "http://127.0.0.1:8317")
        guard let baseURL else { throw CLIProxyUsageFixtureParserError.invalidBaseURL }

        let rawEvents = fixture.events
        let events = (rawEvents ?? []).map(\.event)
        let statsBackend = fixture.statsBackend ?? (rawEvents == nil ? .proxyOnly : .fixture)
        let fetchedAt = fixture.fetchedAt ?? now
        let windows = statsBackend.hasUsageHistory ? CLIProxyUsageMetricsCalculator.rollingWindows(events: events, now: now) : []
        let velocities = statsBackend.hasUsageHistory ? CLIProxyUsageMetricsCalculator.velocities(for: windows) : []
        let models = modelUsage(fixtureModels: fixture.models ?? [], events: events)
        let sessions = statsBackend.hasUsageHistory ? CLIProxyUsageMetricsCalculator.sessionUsage(events: events) : []
        let accounts = accountUsage(fixtureAccounts: fixture.accounts ?? [], events: events, now: now)
        let warnings = buildWarnings(fixture: fixture, statsBackend: statsBackend)
        let missingCapabilities = missingCapabilities(CapabilityInput(
            reachable: fixture.reachable ?? true,
            statsBackend: statsBackend,
            accounts: accounts,
            models: models,
            sessions: sessions,
            windows: windows
        ))
        return CLIProxyUsageSnapshot(
            fetchedAt: fetchedAt,
            baseURL: baseURL,
            isProxyReachable: fixture.reachable ?? true,
            version: fixture.version,
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

    private static func accountUsage(
        fixtureAccounts: [Account],
        events: [CLIProxyUsageEvent],
        now: Date
    ) -> [CLIProxyAccountUsage] {
        let accountsFromEvents = Dictionary(grouping: events.compactMap(\.accountID)) { $0 }
            .keys
            .sorted()
            .map { accountID in
                Account(
                    id: accountID,
                    displayName: nil,
                    providerKind: nil,
                    status: nil,
                    activeSessionCount: nil,
                    quota: nil,
                    lastUsedAt: nil,
                    recentFailure: nil
                )
            }
        let mergedAccounts = mergeAccounts(fixtureAccounts + accountsFromEvents)

        return mergedAccounts.map { account in
            let id = CLIProxyUsageRedactor.safeIdentifier(account.id, prefix: "acct")
            let accountEvents = events.filter { $0.accountID == id }
            let accountWindows = windowsForAccount(events: accountEvents, now: now)
            let displayName = CLIProxyUsageRedactor.safeDisplayName(account.displayName, fallback: id)
            let base = CLIProxyAccountUsage(
                id: id,
                displayName: displayName,
                providerKind: account.providerKind ?? "unknown",
                status: account.status ?? .unknown,
                activeSessionCount: account.activeSessionCount,
                quota: account.quota,
                lastUsedAt: account.lastUsedAt ?? accountEvents.map(\.timestamp).max(),
                recentFailure: account.recentFailure ?? latestFailure(from: accountEvents),
                recent: accountWindows,
                capacity: nil
            )
            let capacity = CLIProxyUsageMetricsCalculator.capacity(
                account: base,
                currentVelocity: CLIProxyUsageMetricsCalculator.velocities(for: accountWindows).first,
                now: now
            )
            return CLIProxyAccountUsage(
                id: base.id,
                displayName: base.displayName,
                providerKind: base.providerKind,
                status: base.status,
                activeSessionCount: base.activeSessionCount,
                quota: base.quota,
                lastUsedAt: base.lastUsedAt,
                recentFailure: base.recentFailure,
                recent: base.recent,
                capacity: capacity
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func modelUsage(fixtureModels: [Model], events: [CLIProxyUsageEvent]) -> [CLIProxyModelUsage] {
        let calculated = CLIProxyUsageMetricsCalculator.modelUsage(events: events)
        guard !calculated.isEmpty else {
            return fixtureModels.filter(\.hasUsageInputs).map(\.usage).sorted { $0.totalTokens > $1.totalTokens }
        }
        return calculated
    }

    private static func windowsForAccount(events: [CLIProxyUsageEvent], now: Date) -> [CLIProxyUsageWindow] {
        guard !events.isEmpty else { return [] }
        return CLIProxyUsageMetricsCalculator.rollingWindows(events: events, now: now)
    }

    private static func latestFailure(from events: [CLIProxyUsageEvent]) -> CLIProxyUsageFailure? {
        events
            .filter { $0.errorCode != nil }
            .max { $0.timestamp < $1.timestamp }
            .flatMap { event in
                event.errorCode.map { CLIProxyUsageFailure(occurredAt: event.timestamp, message: $0) }
            }
    }

    private static func buildWarnings(fixture: Fixture, statsBackend: CLIProxyStatsBackend) -> [CLIProxyUsageWarning] {
        var warnings = (fixture.warnings ?? []).enumerated().map { index, warning in
            CLIProxyUsageWarning(
                id: warning.id ?? "fixture-warning-\(index)",
                severity: warning.severity ?? .warning,
                message: warning.message
            )
        }
        if fixture.reachable == false {
            warnings.append(CLIProxyUsageWarning(
                id: "proxy-offline",
                severity: .warning,
                message: "CLIProxyAPI is not reachable on the detected local base URL"
            ))
        } else if !statsBackend.hasUsageHistory {
            warnings.append(CLIProxyUsageWarning(
                id: "stats-unavailable",
                severity: .info,
                message: "CLIProxyAPI is reachable, but no usage statistics backend was detected"
            ))
        }
        return warnings
    }

    private static func missingCapabilities(_ input: CapabilityInput) -> [CLIProxyMissingCapability] {
        var missing: [CLIProxyMissingCapability] = []
        if !input.reachable {
            missing.append(CLIProxyMissingCapability(
                id: "proxy",
                capability: "Proxy reachability",
                reason: "No local CLIProxyAPI-compatible endpoint responded"
            ))
        }
        if !input.statsBackend.hasUsageHistory {
            missing.append(CLIProxyMissingCapability(
                id: "usage-history",
                capability: "Usage history",
                reason: "No Redis-queue collector, app-owned SQLite snapshot endpoint, dashboard, or built-in stats source was detected"
            ))
        }
        if input.accounts.allSatisfy({ $0.quota == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "quota",
                capability: "Quota windows",
                reason: "Detected stats do not include account quota or reset-window data"
            ))
        }
        guard input.statsBackend.hasUsageHistory else { return missing }
        if input.models.allSatisfy({ $0.cacheReadTokens == nil && $0.cacheWriteTokens == nil }),
           input.windows.allSatisfy({ $0.cacheReadTokens == nil && $0.cacheWriteTokens == nil })
        {
            missing.append(CLIProxyMissingCapability(
                id: "cache-tokens",
                capability: "Cache token metrics",
                reason: "Detected stats do not include cache read/write token counts"
            ))
        }
        if input.models.allSatisfy({ $0.costEstimateUSD == nil }),
           input.windows.allSatisfy({ $0.costEstimateUSD == nil })
        {
            missing.append(CLIProxyMissingCapability(
                id: "cost-estimates",
                capability: "Cost estimates",
                reason: "Detected stats do not include cost estimates"
            ))
        }
        if input.models.allSatisfy({ $0.averageLatencyMS == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "latency",
                capability: "Latency metrics",
                reason: "Detected stats do not include request latency"
            ))
        }
        if input.models.allSatisfy({ $0.averageTimeToFirstTokenMS == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "time-to-first-token",
                capability: "Time to first token",
                reason: "Detected stats do not include first-token timing"
            ))
        }
        if input.models.allSatisfy({ $0.generationTokensPerSecond == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "generation-throughput",
                capability: "Generation throughput",
                reason: "Detected stats do not include generation duration"
            ))
        }
        if input.sessions.isEmpty {
            missing.append(CLIProxyMissingCapability(
                id: "agent-attribution",
                capability: "Agent attribution",
                reason: "Detected stats do not include request session identifiers to join with agent registry labels"
            ))
        }
        return missing
    }

    private static func mergeAccounts(_ accounts: [Account]) -> [Account] {
        var byID: [String: Account] = [:]
        for account in accounts {
            let id = CLIProxyUsageRedactor.safeIdentifier(account.id, prefix: "acct")
            if byID[id] == nil {
                byID[id] = Account(
                    id: id,
                    displayName: account.displayName,
                    providerKind: account.providerKind,
                    status: account.status,
                    activeSessionCount: account.activeSessionCount,
                    quota: account.quota,
                    lastUsedAt: account.lastUsedAt,
                    recentFailure: account.recentFailure
                )
            }
        }
        return Array(byID.values)
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            return AIUsageParserSupport.unixDate(from: seconds)
        }
        let string = try container.decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        if let date = withFraction.date(from: string) ?? withoutFraction.date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
    }

    private struct Fixture: Decodable {
        let baseURL: URL?
        let fetchedAt: Date?
        let reachable: Bool?
        let version: String?
        let statsBackend: CLIProxyStatsBackend?
        let accounts: [Account]?
        let models: [Model]?
        let events: [Event]?
        let warnings: [Warning]?
    }

    private struct CapabilityInput {
        let reachable: Bool
        let statsBackend: CLIProxyStatsBackend
        let accounts: [CLIProxyAccountUsage]
        let models: [CLIProxyModelUsage]
        let sessions: [CLIProxySessionUsage]
        let windows: [CLIProxyUsageWindow]
    }

    private struct Account: Decodable {
        let id: String?
        let displayName: String?
        let providerKind: String?
        let status: CLIProxyAccountStatus?
        let activeSessionCount: Int?
        let quota: CLIProxyQuotaWindow?
        let lastUsedAt: Date?
        let recentFailure: CLIProxyUsageFailure?
    }

    private struct Model: Decodable {
        let model: String
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let requestCount: Int?
        let errorCount: Int?
        let averageLatencyMS: Double?
        let averageTimeToFirstTokenMS: Double?
        let generationTokensPerSecond: Double?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let costEstimateUSD: Double?

        var hasUsageInputs: Bool {
            promptTokens != nil
                || completionTokens != nil
                || totalTokens != nil
                || requestCount != nil
                || errorCount != nil
                || averageLatencyMS != nil
                || averageTimeToFirstTokenMS != nil
                || generationTokensPerSecond != nil
                || cacheReadTokens != nil
                || cacheWriteTokens != nil
                || costEstimateUSD != nil
        }

        var usage: CLIProxyModelUsage {
            CLIProxyModelUsage(
                id: model,
                model: CLIProxyUsageRedactor.redact(model),
                promptTokens: max(0, promptTokens ?? 0),
                completionTokens: max(0, completionTokens ?? 0),
                totalTokens: max(0, totalTokens ?? (promptTokens ?? 0) + (completionTokens ?? 0)),
                requestCount: max(0, requestCount ?? 0),
                errorCount: max(0, errorCount ?? 0),
                averageLatencyMS: averageLatencyMS,
                averageTimeToFirstTokenMS: averageTimeToFirstTokenMS,
                generationTokensPerSecond: generationTokensPerSecond,
                cacheReadTokens: cacheReadTokens.map { max(0, $0) },
                cacheWriteTokens: cacheWriteTokens.map { max(0, $0) },
                costEstimateUSD: costEstimateUSD.map { max(0, $0) }
            )
        }
    }

    private struct Event: Decodable {
        let id: String?
        let timestamp: Date
        let accountID: String?
        let accountDisplayName: String?
        let providerKind: String?
        let model: String?
        let sessionID: String?
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let latencyMS: Int?
        let timeToFirstTokenMS: Int?
        let generationDurationMS: Int?
        let errorCode: String?
        let costEstimateUSD: Double?

        var event: CLIProxyUsageEvent {
            let safeAccountID = CLIProxyUsageRedactor.safeIdentifier(accountID, prefix: "acct")
            let safeSessionID = sessionID.map { CLIProxyUsageRedactor.safeIdentifier($0, prefix: "session") }
            return CLIProxyUsageEvent(
                id: CLIProxyUsageRedactor.safeIdentifier(id ?? "\(timestamp.timeIntervalSince1970)-\(safeAccountID)", prefix: "event"),
                timestamp: timestamp,
                accountID: safeAccountID,
                accountDisplayName: CLIProxyUsageRedactor.safeDisplayName(accountDisplayName, fallback: safeAccountID),
                providerKind: providerKind ?? "unknown",
                model: model.map(CLIProxyUsageRedactor.redact),
                sessionID: safeSessionID,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                latencyMS: latencyMS,
                timeToFirstTokenMS: timeToFirstTokenMS,
                generationDurationMS: generationDurationMS,
                errorCode: errorCode.map(CLIProxyUsageRedactor.redact),
                costEstimateUSD: costEstimateUSD
            )
        }
    }

    private struct Warning: Decodable {
        let id: String?
        let severity: CLIProxyUsageWarningSeverity?
        let message: String
    }
}
