import Foundation

private func normalizedAgentToken(_ value: String?) -> String {
    guard let value else { return "" }
    return value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")
}

private func nonEmptyAgentString(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

enum AgentSessionRole: String, Codable, CaseIterable, Hashable {
    case architect
    case conductor
    case orchestrator
    case subagent
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self.parse(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parse(_ value: String?) -> Self {
        switch normalizedAgentToken(value) {
        case "architect": .architect
        case "conductor": .conductor
        case "orchestrator": .orchestrator
        case "subagent",
             "agent",
             "worker",
             "subworker": .subagent
        default: .unknown
        }
    }

    var displayName: String {
        switch self {
        case .architect: "Architect"
        case .conductor: "Conductor"
        case .orchestrator: "Orchestrator"
        case .subagent: "Subagent"
        case .unknown: "Unknown"
        }
    }

    var sortRank: Int {
        switch self {
        case .architect: 0
        case .conductor: 1
        case .orchestrator: 2
        case .subagent: 3
        case .unknown: 4
        }
    }
}

enum AgentSessionLifecycleStatus: String, Codable, CaseIterable, Hashable {
    case ready
    case running
    case blocked
    case complete
    case failed
    case stale
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self.parse(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parse(_ value: String?) -> Self {
        switch normalizedAgentToken(value) {
        case "ready",
             "idle",
             "queued": .ready
        case "running",
             "active",
             "inprogress",
             "working": .running
        case "blocked",
             "waiting": .blocked
        case "complete",
             "completed",
             "done",
             "success",
             "succeeded": .complete
        case "failed",
             "failure",
             "error": .failed
        case "stale",
             "stalled": .stale
        default: .unknown
        }
    }

    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .running: "Running"
        case .blocked: "Blocked"
        case .complete: "Complete"
        case .failed: "Failed"
        case .stale: "Stale"
        case .unknown: "Unknown"
        }
    }
}

enum AgentSessionProofStatus: String, Codable, CaseIterable, Hashable {
    case unverified
    case promptDelivered
    case toolActive
    case finalReported
    case validated

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self.parse(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parse(_ value: String?) -> Self {
        switch normalizedAgentToken(value) {
        case "promptdelivered",
             "delivered",
             "promptreceived": .promptDelivered
        case "toolactive",
             "toolrunning",
             "toolsactive": .toolActive
        case "finalreported",
             "finalreport",
             "reported": .finalReported
        case "validated",
             "verified",
             "validationpassed": .validated
        default: .unverified
        }
    }

    var displayName: String {
        switch self {
        case .unverified: "Unverified"
        case .promptDelivered: "Prompt delivered"
        case .toolActive: "Tool active"
        case .finalReported: "Final reported"
        case .validated: "Validated"
        }
    }
}

enum AgentSessionRiskFlag: String, Codable, CaseIterable, Hashable {
    case sharedWorktree
    case dirtyWorktree
    case missingLog
    case staleLog
    case unverifiedPromptReceipt
    case unvalidatedFinalReport
    case staleChild
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self.parse(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parse(_ value: String?) -> Self {
        switch normalizedAgentToken(value) {
        case "sharedworktree",
             "sameworktree",
             "sharedcwd": .sharedWorktree
        case "dirtyworktree",
             "dirty": .dirtyWorktree
        case "missinglog",
             "logmissing",
             "nocodexlog": .missingLog
        case "stalelog",
             "staleactivity",
             "nologactivity": .staleLog
        case "unverifiedpromptreceipt",
             "unverifiedprompt",
             "promptunverified": .unverifiedPromptReceipt
        case "unvalidatedfinalreport",
             "finalreportunvalidated",
             "validationpending": .unvalidatedFinalReport
        case "stalechild",
             "stalechildren": .staleChild
        default: .unknown
        }
    }

    static func sorted(_ values: Set<Self>) -> [Self] {
        values.sorted { lhs, rhs in
            if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
            return lhs.rawValue < rhs.rawValue
        }
    }

    var sortRank: Int {
        switch self {
        case .sharedWorktree: 0
        case .dirtyWorktree: 1
        case .missingLog: 2
        case .staleLog: 3
        case .unverifiedPromptReceipt: 4
        case .unvalidatedFinalReport: 5
        case .staleChild: 6
        case .unknown: 7
        }
    }
}

enum AgentSessionAttributionConfidence: String, Codable, CaseIterable, Hashable {
    case unknown
    case suggested
    case confirmed

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self.parse(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parse(_ value: String?) -> Self {
        switch normalizedAgentToken(value) {
        case "confirmed",
             "explicit": .confirmed
        case "suggested",
             "inferred",
             "probable": .suggested
        default: .unknown
        }
    }
}

struct AgentSessionReferences: Codable, Equatable, Hashable {
    var tmuxSession: String?
    var cwd: String?
    var worktreePath: String?
    var branch: String?
    var codexLog: String?
    var finalReport: String?
    var lastPromptMarker: String?

    var worktreeIdentity: String? {
        nonEmptyAgentString(worktreePath) ?? nonEmptyAgentString(cwd)
    }

    init(
        tmuxSession: String? = nil,
        cwd: String? = nil,
        worktreePath: String? = nil,
        branch: String? = nil,
        codexLog: String? = nil,
        finalReport: String? = nil,
        lastPromptMarker: String? = nil
    ) {
        self.tmuxSession = nonEmptyAgentString(tmuxSession)
        self.cwd = nonEmptyAgentString(cwd)
        self.worktreePath = nonEmptyAgentString(worktreePath)
        self.branch = nonEmptyAgentString(branch)
        self.codexLog = nonEmptyAgentString(codexLog)
        self.finalReport = nonEmptyAgentString(finalReport)
        self.lastPromptMarker = nonEmptyAgentString(lastPromptMarker)
    }
}

struct AgentSessionAttribution: Codable, Equatable, Hashable {
    var confidence: AgentSessionAttributionConfidence
    var requestSessionIds: [String]
    var conversationIds: [String]
    var labels: [String]

    init(
        confidence: AgentSessionAttributionConfidence = .unknown,
        requestSessionIds: [String] = [],
        conversationIds: [String] = [],
        labels: [String] = []
    ) {
        self.confidence = confidence
        self.requestSessionIds = requestSessionIds.compactMap(nonEmptyAgentString)
        self.conversationIds = conversationIds.compactMap(nonEmptyAgentString)
        self.labels = labels.compactMap(nonEmptyAgentString)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            confidence: container.decodeIfPresent(AgentSessionAttributionConfidence.self, forKey: .confidence) ?? .unknown,
            requestSessionIds: container.decodeIfPresent([String].self, forKey: .requestSessionIds) ?? [],
            conversationIds: container.decodeIfPresent([String].self, forKey: .conversationIds) ?? [],
            labels: container.decodeIfPresent([String].self, forKey: .labels) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(requestSessionIds, forKey: .requestSessionIds)
        try container.encode(conversationIds, forKey: .conversationIds)
        try container.encode(labels, forKey: .labels)
    }

    private enum CodingKeys: String, CodingKey {
        case confidence
        case requestSessionIds
        case conversationIds
        case labels
    }
}

struct AgentSession: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var parentID: String?
    var role: AgentSessionRole
    var title: String
    var status: AgentSessionLifecycleStatus
    var proofStatus: AgentSessionProofStatus
    var riskFlags: [AgentSessionRiskFlag]
    var references: AgentSessionReferences
    var attribution: AgentSessionAttribution
    var updatedAt: Date?
    var sortOrder: Int

    var displayName: String { title.isEmpty ? id : title }

    init(
        id: String,
        parentID: String? = nil,
        role: AgentSessionRole = .unknown,
        title: String? = nil,
        status: AgentSessionLifecycleStatus = .unknown,
        proofStatus: AgentSessionProofStatus = .unverified,
        riskFlags: [AgentSessionRiskFlag] = [],
        references: AgentSessionReferences = AgentSessionReferences(),
        attribution: AgentSessionAttribution = AgentSessionAttribution(),
        updatedAt: Date? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.parentID = nonEmptyAgentString(parentID)
        self.role = role
        self.title = nonEmptyAgentString(title) ?? id
        self.status = status
        self.proofStatus = proofStatus
        self.riskFlags = AgentSessionRiskFlag.sorted(Set(riskFlags))
        self.references = references
        self.attribution = attribution
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }

    func addingRiskFlags(_ flags: Set<AgentSessionRiskFlag>) -> Self {
        var copy = self
        copy.riskFlags = AgentSessionRiskFlag.sorted(Set(riskFlags).union(flags))
        return copy
    }

    func withProofStatus(_ proofStatus: AgentSessionProofStatus) -> Self {
        var copy = self
        copy.proofStatus = proofStatus
        return copy
    }
}

struct AgentSessionNode: Identifiable, Equatable, Hashable {
    var id: String { session.id }
    var session: AgentSession
    var children: [AgentSessionNode]

    var flattened: [AgentSessionNode] {
        [self] + children.flatMap(\.flattened)
    }
}

struct AgentUsageAttributionLabels: Identifiable, Equatable, Hashable {
    var id: String { sessionID }
    let sessionID: String
    let displayLabel: String
    let hierarchyLabel: String
    let roleLabel: String
    let worktreeLabel: String?
    let branchLabel: String?
    let confidence: AgentSessionAttributionConfidence
    let joinKeys: [String]
}

struct AgentSessionRegistrySnapshot: Equatable {
    let generatedAt: Date?
    let sessions: [AgentSession]
    let roots: [AgentSessionNode]
    let attributionLabelsBySessionID: [String: AgentUsageAttributionLabels]
    let attributionLabelsByJoinKey: [String: AgentUsageAttributionLabels]

    func session(id: String) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    func node(id: String) -> AgentSessionNode? {
        roots.flatMap(\.flattened).first { $0.id == id }
    }

    func attributionLabels(forID id: String) -> AgentUsageAttributionLabels? {
        attributionLabelsBySessionID[id]
    }

    func attributionLabels(matchingJoinKey key: String) -> AgentUsageAttributionLabels? {
        attributionLabelsByJoinKey[key]
    }
}
