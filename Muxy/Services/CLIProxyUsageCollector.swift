import Foundation
import SQLite3

protocol CLIProxyUsageEventPersisting: Sendable {
    func append(_ events: [CLIProxyUsageEvent], pruningBefore cutoff: Date?) throws
    func loadEvents(since cutoff: Date?) throws -> [CLIProxyUsageEvent]
}

enum CLIProxyUsageEventPersistenceError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}

struct CLIProxyUsageSQLiteEventStore: CLIProxyUsageEventPersisting {
    let fileURL: URL

    init(fileURL: URL = MuxyFileStorage.fileURL(filename: "cliproxyapi-usage.sqlite")) {
        self.fileURL = fileURL
    }

    func append(_ events: [CLIProxyUsageEvent], pruningBefore cutoff: Date?) throws {
        guard !events.isEmpty || cutoff != nil else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: FilePermissions.privateDirectory]
        )
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try createSchema(in: db)
        if let cutoff {
            try prune(before: cutoff, in: db)
        }
        guard !events.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION", in: db)
        do {
            for event in events {
                try insert(event.sanitizedForLocalPersistence, in: db)
            }
            try execute("COMMIT", in: db)
        } catch {
            try? execute("ROLLBACK", in: db)
            throw error
        }
    }

    func loadEvents(since cutoff: Date?) throws -> [CLIProxyUsageEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try createSchema(in: db)

        let sql = if cutoff == nil {
            """
            SELECT id, timestamp, account_id, account_display_name, provider_kind, model, session_id,
                   prompt_tokens, completion_tokens, total_tokens, cache_read_tokens, cache_write_tokens,
                   latency_ms, time_to_first_token_ms, generation_duration_ms, error_code, cost_estimate_usd
            FROM usage_events
            ORDER BY timestamp ASC, id ASC
            """
        } else {
            """
            SELECT id, timestamp, account_id, account_display_name, provider_kind, model, session_id,
                   prompt_tokens, completion_tokens, total_tokens, cache_read_tokens, cache_write_tokens,
                   latency_ms, time_to_first_token_ms, generation_duration_ms, error_code, cost_estimate_usd
            FROM usage_events
            WHERE timestamp >= ?
            ORDER BY timestamp ASC, id ASC
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CLIProxyUsageEventPersistenceError.prepareFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(statement) }
        if let cutoff {
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        }

        var events: [CLIProxyUsageEvent] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw CLIProxyUsageEventPersistenceError.stepFailed(errorMessage(db))
            }
            events.append(CLIProxyUsageEvent(
                id: columnText(statement, 0) ?? "event-unknown",
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                accountID: columnText(statement, 2),
                accountDisplayName: columnText(statement, 3),
                providerKind: columnText(statement, 4) ?? "unknown",
                model: columnText(statement, 5),
                sessionID: columnText(statement, 6),
                promptTokens: columnInt(statement, 7),
                completionTokens: columnInt(statement, 8),
                totalTokens: columnInt(statement, 9),
                cacheReadTokens: columnInt(statement, 10),
                cacheWriteTokens: columnInt(statement, 11),
                latencyMS: columnInt(statement, 12),
                timeToFirstTokenMS: columnInt(statement, 13),
                generationDurationMS: columnInt(statement, 14),
                errorCode: columnText(statement, 15),
                costEstimateUSD: columnDouble(statement, 16)
            ))
        }
        return events
    }

    private func openDatabase() throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else {
            let message = db.map(errorMessage) ?? "unknown SQLite open error"
            if let db { sqlite3_close(db) }
            throw CLIProxyUsageEventPersistenceError.openFailed(message)
        }
        return db
    }

    private func createSchema(in db: OpaquePointer?) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS usage_events (
            id TEXT PRIMARY KEY NOT NULL,
            timestamp REAL NOT NULL,
            account_id TEXT,
            account_display_name TEXT,
            provider_kind TEXT NOT NULL,
            model TEXT,
            session_id TEXT,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            total_tokens INTEGER,
            cache_read_tokens INTEGER,
            cache_write_tokens INTEGER,
            latency_ms INTEGER,
            time_to_first_token_ms INTEGER,
            generation_duration_ms INTEGER,
            error_code TEXT,
            cost_estimate_usd REAL
        )
        """, in: db)
        try execute("CREATE INDEX IF NOT EXISTS usage_events_timestamp_idx ON usage_events(timestamp)", in: db)
    }

    private func insert(_ event: CLIProxyUsageEvent, in db: OpaquePointer?) throws {
        let sql = """
        INSERT OR REPLACE INTO usage_events (
            id, timestamp, account_id, account_display_name, provider_kind, model, session_id,
            prompt_tokens, completion_tokens, total_tokens, cache_read_tokens, cache_write_tokens,
            latency_ms, time_to_first_token_ms, generation_duration_ms, error_code, cost_estimate_usd
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CLIProxyUsageEventPersistenceError.prepareFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, event.id)
        sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
        bindText(statement, 3, event.accountID)
        bindText(statement, 4, event.accountDisplayName)
        bindText(statement, 5, event.providerKind)
        bindText(statement, 6, event.model)
        bindText(statement, 7, event.sessionID)
        bindInt(statement, 8, event.promptTokens)
        bindInt(statement, 9, event.completionTokens)
        bindInt(statement, 10, event.totalTokens)
        bindInt(statement, 11, event.cacheReadTokens)
        bindInt(statement, 12, event.cacheWriteTokens)
        bindInt(statement, 13, event.latencyMS)
        bindInt(statement, 14, event.timeToFirstTokenMS)
        bindInt(statement, 15, event.generationDurationMS)
        bindText(statement, 16, event.errorCode)
        bindDouble(statement, 17, event.costEstimateUSD)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CLIProxyUsageEventPersistenceError.stepFailed(errorMessage(db))
        }
    }

    private func prune(before cutoff: Date, in db: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM usage_events WHERE timestamp < ?", -1, &statement, nil) == SQLITE_OK else {
            throw CLIProxyUsageEventPersistenceError.prepareFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CLIProxyUsageEventPersistenceError.stepFailed(errorMessage(db))
        }
    }

    private func execute(_ sql: String, in db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CLIProxyUsageEventPersistenceError.stepFailed(errorMessage(db))
        }
    }
}

enum CLIProxyUsageQueueRecordParser {
    static func parseEvents(from data: Data) throws -> [CLIProxyUsageEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDate(from:))
        return try decoder.decode([QueueRecord].self, from: data).compactMap(\.event)
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
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid CLIProxyAPI usage queue timestamp")
    }

    private struct QueueRecord: Decodable {
        let timestamp: Date?
        let latencyMS: Int?
        let source: String?
        let authIndex: String?
        let tokens: TokenStats?
        let failed: Bool?
        let fail: FailDetail?
        let provider: String?
        let model: String?
        let alias: String?
        let endpoint: String?
        let authType: String?
        let apiKey: String?
        let requestID: String?
        let sessionID: String?
        let conversationID: String?
        let threadID: String?
        let clientRequestID: String?

        var event: CLIProxyUsageEvent? {
            guard let timestamp else { return nil }
            let providerKind = nonEmpty(provider) ?? "unknown"
            let accountID = accountIdentifier(providerKind: providerKind)
            let displayName = accountDisplayName(providerKind: providerKind, fallbackID: accountID)
            let completion = (tokens?.outputTokens).map { max(0, $0) + max(0, tokens?.reasoningTokens ?? 0) }
            let total = tokens?.totalTokens.map { max(0, $0) }
            let error = errorMessage
            let rawID = nonEmpty(requestID)
                ?? [timestamp.timeIntervalSince1970.description, providerKind, modelName ?? "unknown", accountID].joined(separator: ":")
            return CLIProxyUsageEvent(
                id: CLIProxyUsageRedactor.safeIdentifier(rawID, prefix: "event"),
                timestamp: timestamp,
                accountID: accountID,
                accountDisplayName: displayName,
                providerKind: CLIProxyUsageRedactor.redact(providerKind),
                model: modelName.map(CLIProxyUsageRedactor.redact),
                sessionID: sessionIdentifier,
                promptTokens: tokens?.inputTokens.map { max(0, $0) },
                completionTokens: completion,
                totalTokens: total,
                cacheReadTokens: tokens?.cachedTokens.map { max(0, $0) },
                cacheWriteTokens: nil,
                latencyMS: latencyMS.map { max(0, $0) },
                errorCode: error,
                costEstimateUSD: nil
            )
        }

        private var modelName: String? {
            nonEmpty(alias) ?? nonEmpty(model)
        }

        private var sessionIdentifier: String? {
            let raw = nonEmpty(sessionID)
                ?? nonEmpty(conversationID)
                ?? nonEmpty(threadID)
                ?? nonEmpty(clientRequestID)
            guard let raw else { return nil }
            return CLIProxyUsageRedactor.safeIdentifier(raw, prefix: "session")
        }

        private var errorMessage: String? {
            guard failed == true else { return nil }
            let status = fail?.statusCode ?? 500
            if let body = nonEmpty(fail?.body) {
                return CLIProxyUsageRedactor.redact("HTTP \(status): \(body)")
            }
            return "HTTP \(status)"
        }

        private func accountIdentifier(providerKind: String) -> String {
            if let apiKey = nonEmpty(apiKey) {
                return CLIProxyUsageRedactor.safeIdentifier("api-key:\(apiKey)", prefix: "acct")
            }
            let raw = [providerKind, nonEmpty(authType), nonEmpty(authIndex), nonEmpty(source)]
                .compactMap(\.self)
                .joined(separator: ":")
            return CLIProxyUsageRedactor.safeIdentifier(raw.isEmpty ? nil : raw, prefix: "acct")
        }

        private func accountDisplayName(providerKind: String, fallbackID: String) -> String {
            let raw = [providerKind, nonEmpty(authType), nonEmpty(authIndex)]
                .compactMap(\.self)
                .joined(separator: " · ")
            return CLIProxyUsageRedactor.safeDisplayName(raw.isEmpty ? nil : raw, fallback: fallbackID)
        }

        private func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        private enum CodingKeys: String, CodingKey {
            case timestamp
            case latencyMS = "latency_ms"
            case source
            case authIndex = "auth_index"
            case tokens
            case failed
            case fail
            case provider
            case model
            case alias
            case endpoint
            case authType = "auth_type"
            case apiKey = "api_key"
            case requestID = "request_id"
            case sessionID = "session_id"
            case conversationID = "conversation_id"
            case threadID = "thread_id"
            case clientRequestID = "client_request_id"
        }
    }

    private struct TokenStats: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let reasoningTokens: Int?
        let cachedTokens: Int?
        let totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case reasoningTokens = "reasoning_tokens"
            case cachedTokens = "cached_tokens"
            case totalTokens = "total_tokens"
        }
    }

    private struct FailDetail: Decodable {
        let statusCode: Int?
        let body: String?

        private enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case body
        }
    }
}

enum CLIProxyUsageSnapshotBuilder {
    static func snapshot(
        baseURL: URL,
        version: String?,
        statsBackend: CLIProxyStatsBackend,
        events: [CLIProxyUsageEvent],
        fetchedAt: Date,
        warnings: [CLIProxyUsageWarning] = []
    ) -> CLIProxyUsageSnapshot {
        let windows = events.isEmpty ? [] : CLIProxyUsageMetricsCalculator.rollingWindows(events: events, now: fetchedAt)
        let velocities = events.isEmpty ? [] : CLIProxyUsageMetricsCalculator.velocities(for: windows)
        let models = CLIProxyUsageMetricsCalculator.modelUsage(events: events)
        let sessions = CLIProxyUsageMetricsCalculator.sessionUsage(events: events)
        let accounts = accountUsage(events: events, now: fetchedAt)
        return CLIProxyUsageSnapshot(
            fetchedAt: fetchedAt,
            baseURL: baseURL,
            isProxyReachable: true,
            version: version,
            statsBackend: statsBackend,
            accounts: accounts,
            models: models,
            sessions: sessions,
            windows: windows,
            velocities: velocities,
            warnings: warnings + emptyCollectorWarning(events: events),
            missingCapabilities: missingCapabilities(
                statsBackend: statsBackend,
                accounts: accounts,
                models: models,
                sessions: sessions,
                windows: windows
            )
        )
    }

    private static func accountUsage(events: [CLIProxyUsageEvent], now: Date) -> [CLIProxyAccountUsage] {
        let grouped = Dictionary(grouping: events) { event in
            CLIProxyUsageRedactor.safeIdentifier(event.accountID, prefix: "acct")
        }
        return grouped.map { accountID, events in
            let latest = events.max { $0.timestamp < $1.timestamp }
            let accountWindows = CLIProxyUsageMetricsCalculator.rollingWindows(events: events, now: now)
            let base = CLIProxyAccountUsage(
                id: accountID,
                displayName: CLIProxyUsageRedactor.safeDisplayName(latest?.accountDisplayName, fallback: accountID),
                providerKind: latest?.providerKind ?? "unknown",
                status: accountStatus(latest: latest, now: now),
                activeSessionCount: Set(events.compactMap(\.sessionID)).isEmpty ? nil : Set(events.compactMap(\.sessionID)).count,
                quota: nil,
                lastUsedAt: latest?.timestamp,
                recentFailure: latestFailure(from: events),
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

    private static func accountStatus(latest: CLIProxyUsageEvent?, now: Date) -> CLIProxyAccountStatus {
        guard let latest else { return .unknown }
        if latest.errorCode != nil { return .error }
        return now.timeIntervalSince(latest.timestamp) <= 600 ? .active : .idle
    }

    private static func latestFailure(from events: [CLIProxyUsageEvent]) -> CLIProxyUsageFailure? {
        events
            .filter { $0.errorCode != nil }
            .max { $0.timestamp < $1.timestamp }
            .flatMap { event in
                event.errorCode.map { CLIProxyUsageFailure(occurredAt: event.timestamp, message: $0) }
            }
    }

    private static func emptyCollectorWarning(events: [CLIProxyUsageEvent]) -> [CLIProxyUsageWarning] {
        guard events.isEmpty else { return [] }
        return [
            CLIProxyUsageWarning(
                id: "collector-empty",
                severity: .info,
                message: "CLIProxyAPI usage queue collector is available, but no usage events have been captured yet"
            ),
        ]
    }

    private static func missingCapabilities(
        statsBackend: CLIProxyStatsBackend,
        accounts: [CLIProxyAccountUsage],
        models: [CLIProxyModelUsage],
        sessions: [CLIProxySessionUsage],
        windows: [CLIProxyUsageWindow]
    ) -> [CLIProxyMissingCapability] {
        var missing: [CLIProxyMissingCapability] = []
        if !statsBackend.hasUsageHistory {
            missing.append(CLIProxyMissingCapability(
                id: "usage-history",
                capability: "Usage history",
                reason: "No Redis-queue collector, app-owned SQLite snapshot endpoint, dashboard, or built-in stats source was detected"
            ))
        }
        if accounts.allSatisfy({ $0.quota == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "quota",
                capability: "Quota windows",
                reason: "Detected stats do not include account quota or reset-window data"
            ))
        }
        guard statsBackend.hasUsageHistory else { return missing }
        if models.allSatisfy({ $0.cacheReadTokens == nil && $0.cacheWriteTokens == nil }),
           windows.allSatisfy({ $0.cacheReadTokens == nil && $0.cacheWriteTokens == nil })
        {
            missing.append(CLIProxyMissingCapability(
                id: "cache-tokens",
                capability: "Cache token metrics",
                reason: "Detected stats do not include cache read/write token counts"
            ))
        }
        if models.allSatisfy({ $0.costEstimateUSD == nil }),
           windows.allSatisfy({ $0.costEstimateUSD == nil })
        {
            missing.append(CLIProxyMissingCapability(
                id: "cost-estimates",
                capability: "Cost estimates",
                reason: "Detected stats do not include cost estimates"
            ))
        }
        if models.allSatisfy({ $0.averageLatencyMS == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "latency",
                capability: "Latency metrics",
                reason: "Detected stats do not include request latency"
            ))
        }
        if models.allSatisfy({ $0.averageTimeToFirstTokenMS == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "time-to-first-token",
                capability: "Time to first token",
                reason: "Detected stats do not include first-token timing"
            ))
        }
        if models.allSatisfy({ $0.generationTokensPerSecond == nil }) {
            missing.append(CLIProxyMissingCapability(
                id: "generation-throughput",
                capability: "Generation throughput",
                reason: "Detected stats do not include generation duration"
            ))
        }
        if sessions.isEmpty {
            missing.append(CLIProxyMissingCapability(
                id: "agent-attribution",
                capability: "Agent attribution",
                reason: "Detected stats do not include request session identifiers to join with agent registry labels"
            ))
        }
        return missing
    }
}

private extension CLIProxyUsageEvent {
    var sanitizedForLocalPersistence: CLIProxyUsageEvent {
        let safeAccountID = CLIProxyUsageRedactor.safeIdentifier(accountID, prefix: "acct")
        let safeSessionID = sessionID.map { CLIProxyUsageRedactor.safeIdentifier($0, prefix: "session") }
        return CLIProxyUsageEvent(
            id: CLIProxyUsageRedactor.safeIdentifier(id, prefix: "event"),
            timestamp: timestamp,
            accountID: safeAccountID,
            accountDisplayName: CLIProxyUsageRedactor.safeDisplayName(accountDisplayName, fallback: safeAccountID),
            providerKind: CLIProxyUsageRedactor.redact(providerKind),
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

private func errorMessage(_ db: OpaquePointer?) -> String {
    guard let db, let raw = sqlite3_errmsg(db) else { return "unknown SQLite error" }
    return String(cString: raw)
}

private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
}

private func bindInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int64(statement, index, sqlite3_int64(value))
}

private func bindDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_double(statement, index, value)
}

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let raw = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: raw)
}

private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, index))
}

private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
