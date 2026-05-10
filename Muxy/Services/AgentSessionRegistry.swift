import Foundation

struct AgentSessionRegistry {
    let fileURL: URL
    var staleLogInterval: TimeInterval
    var fileManager: FileManager
    var now: () -> Date

    init(
        fileURL: URL,
        staleLogInterval: TimeInterval = 300,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.staleLogInterval = staleLogInterval
        self.fileManager = fileManager
        self.now = now
    }

    func loadSnapshot() throws -> AgentSessionRegistrySnapshot {
        let data = try Data(contentsOf: fileURL)
        return try AgentSessionRegistryParser.parseFixture(
            data: data,
            baseURL: fileURL.deletingLastPathComponent(),
            now: now(),
            staleLogInterval: staleLogInterval,
            fileManager: fileManager
        )
    }
}

enum AgentSessionRegistryParser {
    static func parseFixture(
        data: Data,
        baseURL: URL? = nil,
        now: Date = Date(),
        staleLogInterval: TimeInterval = 300,
        deriveFileRisks: Bool = true,
        fileManager: FileManager = .default
    ) throws -> AgentSessionRegistrySnapshot {
        let decoder = registryDecoder()
        if let envelope = try? decoder.decode(RegistryEnvelope.self, from: data) {
            return compose(
                sessions: envelope.sessions.enumerated().map { session(from: $0.element, sortOrder: $0.offset) },
                generatedAt: envelope.generatedAt,
                baseURL: baseURL,
                now: now,
                staleLogInterval: staleLogInterval,
                deriveFileRisks: deriveFileRisks,
                fileManager: fileManager
            )
        }
        let records = try decoder.decode([SessionRecord].self, from: data)
        return compose(
            sessions: records.enumerated().map { session(from: $0.element, sortOrder: $0.offset) },
            generatedAt: nil,
            baseURL: baseURL,
            now: now,
            staleLogInterval: staleLogInterval,
            deriveFileRisks: deriveFileRisks,
            fileManager: fileManager
        )
    }

    static func compose(
        sessions: [AgentSession],
        generatedAt: Date? = nil,
        baseURL: URL? = nil,
        now: Date = Date(),
        staleLogInterval: TimeInterval = 300,
        deriveFileRisks: Bool = true,
        fileManager: FileManager = .default
    ) -> AgentSessionRegistrySnapshot {
        let sharedWorktrees = sharedWorktreeIdentities(sessions)
        let riskContext = RiskDerivationContext(
            sharedWorktrees: sharedWorktrees,
            baseURL: baseURL,
            now: now,
            staleLogInterval: staleLogInterval,
            deriveFileRisks: deriveFileRisks,
            fileManager: fileManager
        )
        var derived = sessions.map { session in
            session.addingRiskFlags(
                derivedRiskFlags(
                    for: session,
                    context: riskContext
                )
            )
        }
        derived = sessionsWithStaleChildRisk(derived)
        let roots = buildHierarchy(from: derived)
        let flat = roots.flatMap(\.flattened).map(\.session)
        return AgentSessionRegistrySnapshot(
            generatedAt: generatedAt,
            sessions: flat,
            roots: roots,
            attributionLabelsBySessionID: attributionLabelsBySessionID(roots: roots)
        )
    }

    private static func session(from record: SessionRecord, sortOrder: Int) -> AgentSession {
        AgentSession(
            id: record.id,
            parentID: record.parentId,
            role: record.role ?? .unknown,
            title: record.title ?? record.name,
            status: record.status ?? .unknown,
            proofStatus: record.proofStatus ?? .unverified,
            riskFlags: record.riskFlags ?? [],
            references: AgentSessionReferences(
                tmuxSession: record.tmuxSession,
                cwd: record.cwd,
                worktreePath: record.worktreePath,
                branch: record.branch,
                codexLog: record.codexLog,
                finalReport: record.finalReport,
                lastPromptMarker: record.lastPromptMarker
            ),
            attribution: record.attribution ?? AgentSessionAttribution(),
            updatedAt: record.updatedAt,
            sortOrder: record.sortOrder ?? sortOrder
        )
    }

    private static func registryDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                return number > 10_000_000_000 ? Date(timeIntervalSince1970: number / 1000) : Date(timeIntervalSince1970: number)
            }
            let string = try container.decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        return decoder
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) {
            return seconds > 10_000_000_000 ? Date(timeIntervalSince1970: seconds / 1000) : Date(timeIntervalSince1970: seconds)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: trimmed) ?? withoutFraction.date(from: trimmed)
    }

    private static func sharedWorktreeIdentities(_ sessions: [AgentSession]) -> Set<String> {
        let identities = sessions.compactMap(\.references.worktreeIdentity)
        let counts = Dictionary(grouping: identities, by: { $0 }).mapValues(\.count)
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private static func derivedRiskFlags(
        for session: AgentSession,
        context: RiskDerivationContext
    ) -> Set<AgentSessionRiskFlag> {
        var flags = Set<AgentSessionRiskFlag>()
        if let worktree = session.references.worktreeIdentity, context.sharedWorktrees.contains(worktree) {
            flags.insert(.sharedWorktree)
        }
        if session.status == .running, session.proofStatus == .unverified {
            flags.insert(.unverifiedPromptReceipt)
        }
        if session.proofStatus == .finalReported
            || (session.references.finalReport != nil && session.proofStatus != .validated)
        {
            flags.insert(.unvalidatedFinalReport)
        }
        guard context.deriveFileRisks else { return flags }
        guard let logPath = session.references.codexLog else {
            flags.insert(.missingLog)
            return flags
        }
        guard let logURL = resolvedURL(for: logPath, baseURL: context.baseURL),
              context.fileManager.fileExists(atPath: logURL.path)
        else {
            flags.insert(.missingLog)
            return flags
        }
        guard session.status == .running else { return flags }
        let modified = (try? context.fileManager.attributesOfItem(atPath: logURL.path)[.modificationDate]) as? Date
        if let modified, context.now.timeIntervalSince(modified) > context.staleLogInterval {
            flags.insert(.staleLog)
        }
        return flags
    }

    private static func resolvedURL(for path: String, baseURL: URL?) -> URL? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (baseURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(path)
    }

    private static func sessionsWithStaleChildRisk(_ sessions: [AgentSession]) -> [AgentSession] {
        let childrenByParent = Dictionary(grouping: sessions.compactMap { session -> (String, AgentSession)? in
            guard let parentID = session.parentID else { return nil }
            return (parentID, session)
        }, by: \.0).mapValues { $0.map(\.1) }

        return sessions.map { session in
            guard hasStaleDescendant(session.id, childrenByParent: childrenByParent, seen: []) else { return session }
            return session.addingRiskFlags([.staleChild])
        }
    }

    private static func hasStaleDescendant(
        _ id: String,
        childrenByParent: [String: [AgentSession]],
        seen: Set<String>
    ) -> Bool {
        guard !seen.contains(id) else { return false }
        let nextSeen = seen.union([id])
        for child in childrenByParent[id] ?? [] {
            if child.status == .stale || child.riskFlags.contains(.staleLog) {
                return true
            }
            if hasStaleDescendant(child.id, childrenByParent: childrenByParent, seen: nextSeen) {
                return true
            }
        }
        return false
    }

    private static func buildHierarchy(from sessions: [AgentSession]) -> [AgentSessionNode] {
        var byID: [String: AgentSession] = [:]
        for session in sortedSessions(sessions) where byID[session.id] == nil {
            byID[session.id] = session
        }
        let childrenByParent = Dictionary(grouping: byID.values.compactMap { session -> (String, AgentSession)? in
            guard let parentID = session.parentID, byID[parentID] != nil, parentID != session.id else { return nil }
            return (parentID, session)
        }, by: \.0).mapValues { sortedSessions($0.map(\.1)) }
        let rootSessions = sortedSessions(byID.values.filter { session in
            guard let parentID = session.parentID else { return true }
            return byID[parentID] == nil || parentID == session.id
        })
        return rootSessions.map { buildNode(session: $0, childrenByParent: childrenByParent, seen: []) }
    }

    private static func buildNode(
        session: AgentSession,
        childrenByParent: [String: [AgentSession]],
        seen: Set<String>
    ) -> AgentSessionNode {
        guard !seen.contains(session.id) else {
            return AgentSessionNode(session: session, children: [])
        }
        let nextSeen = seen.union([session.id])
        return AgentSessionNode(
            session: session,
            children: (childrenByParent[session.id] ?? []).map {
                buildNode(session: $0, childrenByParent: childrenByParent, seen: nextSeen)
            }
        )
    }

    private static func sortedSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.role.sortRank != rhs.role.sortRank { return lhs.role.sortRank < rhs.role.sortRank }
            let lhsName = lhs.displayName.lowercased()
            let rhsName = rhs.displayName.lowercased()
            if lhsName != rhsName { return lhsName < rhsName }
            return lhs.id < rhs.id
        }
    }

    private static func attributionLabelsBySessionID(roots: [AgentSessionNode]) -> [String: AgentUsageAttributionLabels] {
        var labels: [String: AgentUsageAttributionLabels] = [:]
        for root in roots {
            collectAttributionLabels(node: root, path: [], labels: &labels)
        }
        return labels
    }

    private static func collectAttributionLabels(
        node: AgentSessionNode,
        path: [String],
        labels: inout [String: AgentUsageAttributionLabels]
    ) {
        let session = node.session
        let hierarchy = path + [session.displayName]
        labels[session.id] = AgentUsageAttributionLabels(
            sessionID: session.id,
            displayLabel: session.displayName,
            hierarchyLabel: hierarchy.joined(separator: " / "),
            roleLabel: session.role.displayName,
            worktreeLabel: session.references.worktreeIdentity,
            branchLabel: session.references.branch,
            confidence: session.attribution.confidence,
            joinKeys: joinKeys(for: session)
        )
        for child in node.children {
            collectAttributionLabels(node: child, path: hierarchy, labels: &labels)
        }
    }

    private static func joinKeys(for session: AgentSession) -> [String] {
        var keys = ["agent:\(session.id)", "role:\(session.role.rawValue)"]
        if let branch = session.references.branch { keys.append("branch:\(branch)") }
        if let log = session.references.codexLog { keys.append("codex-log:\(log)") }
        if let cwd = session.references.cwd { keys.append("cwd:\(cwd)") }
        if let worktree = session.references.worktreePath { keys.append("worktree:\(worktree)") }
        if let tmux = session.references.tmuxSession { keys.append("tmux:\(tmux)") }
        keys.append(contentsOf: session.attribution.conversationIds.map { "conversation:\($0)" })
        keys.append(contentsOf: session.attribution.labels.map { "label:\($0)" })
        keys.append(contentsOf: session.attribution.requestSessionIds.map { "request-session:\($0)" })
        return Array(Set(keys)).sorted()
    }
}

private struct RegistryEnvelope: Decodable {
    let generatedAt: Date?
    let sessions: [SessionRecord]
}

private struct RiskDerivationContext {
    let sharedWorktrees: Set<String>
    let baseURL: URL?
    let now: Date
    let staleLogInterval: TimeInterval
    let deriveFileRisks: Bool
    let fileManager: FileManager
}

private struct SessionRecord: Decodable {
    let id: String
    let parentId: String?
    let role: AgentSessionRole?
    let title: String?
    let name: String?
    let status: AgentSessionLifecycleStatus?
    let proofStatus: AgentSessionProofStatus?
    let riskFlags: [AgentSessionRiskFlag]?
    let tmuxSession: String?
    let cwd: String?
    let worktreePath: String?
    let branch: String?
    let codexLog: String?
    let finalReport: String?
    let lastPromptMarker: String?
    let attribution: AgentSessionAttribution?
    let updatedAt: Date?
    let sortOrder: Int?
}
