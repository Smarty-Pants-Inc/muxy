import Foundation

enum CLIProxyStatsBackend: String, Codable, Equatable {
    case unavailable
    case proxyOnly
    case managementOnly
    case usageQueue
    case sqlite
    case dashboard
    case builtIn
    case fixture

    var hasUsageHistory: Bool {
        switch self {
        case .usageQueue,
             .sqlite,
             .dashboard,
             .builtIn,
             .fixture:
            true
        case .unavailable,
             .proxyOnly,
             .managementOnly:
            false
        }
    }

    var displayName: String {
        switch self {
        case .unavailable: "Unavailable"
        case .proxyOnly: "Proxy only"
        case .managementOnly: "Management API only"
        case .usageQueue: "Usage queue"
        case .sqlite: "SQLite collector"
        case .dashboard: "Usage dashboard"
        case .builtIn: "Built-in stats"
        case .fixture: "Fixture"
        }
    }
}

enum CLIProxyAccountStatus: String, Codable, Equatable {
    case active
    case idle
    case cooling
    case disabled
    case exhausted
    case error
    case unknown
}

enum CLIProxyUsageWarningSeverity: String, Codable, Equatable {
    case info
    case warning
    case error
}

struct CLIProxyUsageWarning: Identifiable, Equatable {
    let id: String
    let severity: CLIProxyUsageWarningSeverity
    let message: String

    init(id: String, severity: CLIProxyUsageWarningSeverity, message: String) {
        self.id = id
        self.severity = severity
        self.message = CLIProxyUsageRedactor.redact(message)
    }
}

struct CLIProxyMissingCapability: Identifiable, Equatable {
    let id: String
    let capability: String
    let reason: String
}

struct CLIProxyUsageFailure: Codable, Equatable {
    let occurredAt: Date?
    let message: String

    init(occurredAt: Date?, message: String) {
        self.occurredAt = occurredAt
        self.message = CLIProxyUsageRedactor.redact(message)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        occurredAt = try container.decodeIfPresent(Date.self, forKey: .occurredAt)
        message = try CLIProxyUsageRedactor.redact(container.decode(String.self, forKey: .message))
    }
}

struct CLIProxyQuotaWindow: Codable, Equatable {
    let startsAt: Date?
    let resetsAt: Date?
    let limitTokens: Int
    let usedTokens: Int

    var remainingTokens: Int {
        max(0, limitTokens - usedTokens)
    }

    var usedPercent: Double? {
        guard limitTokens > 0 else { return nil }
        return min(100, max(0, Double(usedTokens) / Double(limitTokens) * 100))
    }
}

struct CLIProxyUsageEvent: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let accountID: String?
    let accountDisplayName: String?
    let providerKind: String
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

    init(
        id: String,
        timestamp: Date,
        accountID: String?,
        accountDisplayName: String?,
        providerKind: String,
        model: String?,
        sessionID: String?,
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        latencyMS: Int?,
        timeToFirstTokenMS: Int? = nil,
        generationDurationMS: Int? = nil,
        errorCode: String?,
        costEstimateUSD: Double?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.accountID = accountID
        self.accountDisplayName = accountDisplayName
        self.providerKind = providerKind
        self.model = model
        self.sessionID = sessionID
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.latencyMS = latencyMS
        self.timeToFirstTokenMS = timeToFirstTokenMS
        self.generationDurationMS = generationDurationMS
        self.errorCode = errorCode
        self.costEstimateUSD = costEstimateUSD
    }

    var countedTotalTokens: Int? {
        if let totalTokens { return max(0, totalTokens) }
        let parts = [promptTokens, completionTokens].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 + max(0, $1) }
    }

    var countedCostEstimateUSD: Double? {
        guard let costEstimateUSD else { return nil }
        return max(0, costEstimateUSD)
    }

    var countedPromptTokens: Int {
        max(0, promptTokens ?? 0)
    }

    var countedCompletionTokens: Int {
        max(0, completionTokens ?? 0)
    }

    var countedTimeToFirstTokenMS: Int? {
        guard let timeToFirstTokenMS else { return nil }
        return max(0, timeToFirstTokenMS)
    }

    var countedGenerationDurationMS: Int? {
        guard let generationDurationMS, generationDurationMS > 0 else { return nil }
        return generationDurationMS
    }
}

struct CLIProxyUsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let startsAt: Date
    let endsAt: Date?
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let costEstimateUSD: Double?
    let requestCount: Int
    let errorCount: Int
}

struct CLIProxyUsageVelocity: Identifiable, Equatable {
    let id: String
    let label: String
    let windowDuration: TimeInterval
    let totalTokens: Int
    let requestCount: Int
    let tokensPerMinute: Double
    let requestsPerMinute: Double
}

struct CLIProxyRunwayEstimate: Equatable {
    let minutesUntilExhaustion: Double?
    let exhaustionDate: Date?
    let reason: String?
}

struct CLIProxyCapacityEstimate: Equatable {
    let accountID: String
    let score: Double?
    let runway: CLIProxyRunwayEstimate
    let reason: String?
}

struct CLIProxyRefillEvent: Identifiable, Equatable {
    let id: String
    let accountID: String
    let accountDisplayName: String
    let providerKind: String
    let resetsAt: Date
    let remainingTokens: Int
    let limitTokens: Int
}

struct CLIProxyContextBloatSignal: Equatable {
    let sampleCount: Int
    let firstAveragePromptTokens: Int
    let latestAveragePromptTokens: Int
    let deltaPromptTokens: Int
    let percentChange: Double?

    var isBloating: Bool {
        guard deltaPromptTokens >= 100 else { return false }
        guard let percentChange else { return deltaPromptTokens > 0 }
        return percentChange >= 25
    }
}

struct CLIProxyAccountUsage: Identifiable, Equatable {
    let id: String
    let displayName: String
    let providerKind: String
    let status: CLIProxyAccountStatus
    let activeSessionCount: Int?
    let quota: CLIProxyQuotaWindow?
    let lastUsedAt: Date?
    let recentFailure: CLIProxyUsageFailure?
    let recent: [CLIProxyUsageWindow]
    let capacity: CLIProxyCapacityEstimate?
}

struct CLIProxyModelUsage: Identifiable, Equatable {
    let id: String
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let errorCount: Int
    let averageLatencyMS: Double?
    let averageTimeToFirstTokenMS: Double?
    let generationTokensPerSecond: Double?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let costEstimateUSD: Double?

    init(
        id: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        requestCount: Int,
        errorCount: Int,
        averageLatencyMS: Double?,
        averageTimeToFirstTokenMS: Double? = nil,
        generationTokensPerSecond: Double? = nil,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        costEstimateUSD: Double?
    ) {
        self.id = id
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.averageLatencyMS = averageLatencyMS
        self.averageTimeToFirstTokenMS = averageTimeToFirstTokenMS
        self.generationTokensPerSecond = generationTokensPerSecond
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costEstimateUSD = costEstimateUSD
    }

    var cachePreservationScore: Double? {
        guard promptTokens > 0,
              let cacheReadTokens,
              let cacheWriteTokens
        else { return nil }
        return Double(max(0, cacheReadTokens) + max(0, cacheWriteTokens)) / Double(promptTokens)
    }
}

struct CLIProxySessionAttribution: Equatable {
    let displayLabel: String
    let hierarchyLabel: String
    let roleLabel: String
    let confidence: AgentSessionAttributionConfidence
}

struct CLIProxySessionUsage: Identifiable, Equatable {
    let id: String
    let displayName: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let errorCount: Int
    let modelNames: [String]
    let lastUsedAt: Date?
    let contextBloatSignal: CLIProxyContextBloatSignal?
    let attribution: CLIProxySessionAttribution?

    init(
        id: String,
        displayName: String,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        requestCount: Int,
        errorCount: Int,
        modelNames: [String],
        lastUsedAt: Date?,
        contextBloatSignal: CLIProxyContextBloatSignal? = nil,
        attribution: CLIProxySessionAttribution? = nil
    ) {
        self.id = id
        self.displayName = CLIProxyUsageRedactor.safeDisplayName(displayName, fallback: id)
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.errorCount = errorCount
        self.modelNames = modelNames.map(CLIProxyUsageRedactor.redact)
        self.lastUsedAt = lastUsedAt
        self.contextBloatSignal = contextBloatSignal
        self.attribution = attribution
    }

    func withAttribution(_ labels: AgentUsageAttributionLabels) -> Self {
        CLIProxySessionUsage(
            id: id,
            displayName: displayName,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            requestCount: requestCount,
            errorCount: errorCount,
            modelNames: modelNames,
            lastUsedAt: lastUsedAt,
            contextBloatSignal: contextBloatSignal,
            attribution: CLIProxySessionAttribution(
                displayLabel: labels.displayLabel,
                hierarchyLabel: labels.hierarchyLabel,
                roleLabel: labels.roleLabel,
                confidence: labels.confidence
            )
        )
    }
}

extension CLIProxyUsageWindow {
    var cachePreservationScore: Double? {
        guard promptTokens > 0,
              let cacheReadTokens,
              let cacheWriteTokens
        else { return nil }
        return Double(max(0, cacheReadTokens) + max(0, cacheWriteTokens)) / Double(promptTokens)
    }
}

extension CLIProxyUsageSnapshot {
    var refillTimeline: [CLIProxyRefillEvent] {
        accounts.compactMap { account in
            guard let quota = account.quota,
                  let resetsAt = quota.resetsAt
            else { return nil }
            return CLIProxyRefillEvent(
                id: "\(account.id)-\(Int(resetsAt.timeIntervalSince1970))",
                accountID: account.id,
                accountDisplayName: CLIProxyUsageRedactor.safeDisplayName(account.displayName, fallback: account.id),
                providerKind: CLIProxyUsageRedactor.redact(account.providerKind),
                resetsAt: resetsAt,
                remainingTokens: quota.remainingTokens,
                limitTokens: max(0, quota.limitTokens)
            )
        }
        .sorted {
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            return $0.accountDisplayName.localizedCaseInsensitiveCompare($1.accountDisplayName) == .orderedAscending
        }
    }
}

struct CLIProxyUsageSnapshot: Identifiable, Equatable {
    let id: String
    let fetchedAt: Date
    let baseURL: URL
    let isProxyReachable: Bool
    let version: String?
    let statsBackend: CLIProxyStatsBackend
    let accounts: [CLIProxyAccountUsage]
    let models: [CLIProxyModelUsage]
    let sessions: [CLIProxySessionUsage]
    let windows: [CLIProxyUsageWindow]
    let velocities: [CLIProxyUsageVelocity]
    let warnings: [CLIProxyUsageWarning]
    let missingCapabilities: [CLIProxyMissingCapability]

    init(
        id: String = "cliproxyapi",
        fetchedAt: Date,
        baseURL: URL,
        isProxyReachable: Bool,
        version: String?,
        statsBackend: CLIProxyStatsBackend,
        accounts: [CLIProxyAccountUsage],
        models: [CLIProxyModelUsage],
        sessions: [CLIProxySessionUsage] = [],
        windows: [CLIProxyUsageWindow],
        velocities: [CLIProxyUsageVelocity],
        warnings: [CLIProxyUsageWarning],
        missingCapabilities: [CLIProxyMissingCapability]
    ) {
        self.id = id
        self.fetchedAt = fetchedAt
        self.baseURL = baseURL
        self.isProxyReachable = isProxyReachable
        self.version = version.map(CLIProxyUsageRedactor.redact)
        self.statsBackend = statsBackend
        self.accounts = accounts
        self.models = models
        self.sessions = sessions
        self.windows = windows
        self.velocities = velocities
        self.warnings = warnings
        self.missingCapabilities = missingCapabilities
    }
}
