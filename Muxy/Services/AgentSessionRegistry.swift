import Foundation

enum AgentTreeRegistryLocation {
    static let environmentKey = "SMARTY_CODE_AGENT_SESSION_REGISTRY"
    static let defaultPath = "/tmp/smarty-code-agent-usage-milestone/agent-sessions.json"

    static var defaultURL: URL {
        url(environment: ProcessInfo.processInfo.environment)
    }

    static func url(environment: [String: String]) -> URL {
        if let override = environment[environmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return URL(fileURLWithPath: defaultPath)
    }
}

struct AgentSessionRegistry {
    let fileURL: URL
    var staleLogInterval: TimeInterval
    var fileManager: FileManager
    var dirtyWorktreeChecker: (String) -> Bool
    var tmuxSessionChecker: (String) -> Bool
    var now: () -> Date

    init(
        fileURL: URL,
        staleLogInterval: TimeInterval = 300,
        fileManager: FileManager = .default,
        dirtyWorktreeChecker: @escaping (String) -> Bool = AgentSessionRegistryParser.defaultDirtyWorktreeChecker,
        tmuxSessionChecker: @escaping (String) -> Bool = AgentSessionRegistryParser.defaultTmuxSessionChecker,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.staleLogInterval = staleLogInterval
        self.fileManager = fileManager
        self.dirtyWorktreeChecker = dirtyWorktreeChecker
        self.tmuxSessionChecker = tmuxSessionChecker
        self.now = now
    }

    func loadSnapshot(deriveFileRisks: Bool = true) throws -> AgentSessionRegistrySnapshot {
        let data = try Data(contentsOf: fileURL)
        return try AgentSessionRegistryParser.parseFixture(
            data: data,
            baseURL: fileURL.deletingLastPathComponent(),
            now: now(),
            staleLogInterval: staleLogInterval,
            deriveFileRisks: deriveFileRisks,
            fileManager: fileManager,
            dirtyWorktreeChecker: dirtyWorktreeChecker,
            tmuxSessionChecker: tmuxSessionChecker
        )
    }

    func loadCachedSnapshot(
        maxAge: TimeInterval = 2,
        deriveFileRisks: Bool = true
    ) throws -> AgentSessionRegistrySnapshot {
        try AgentSessionRegistrySnapshotCache.load(
            registry: self,
            maxAge: maxAge,
            deriveFileRisks: deriveFileRisks
        )
    }
}

private enum AgentSessionRegistrySnapshotCache {
    private struct Entry {
        let loadedAt: Date
        let snapshot: AgentSessionRegistrySnapshot
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    static func load(
        registry: AgentSessionRegistry,
        maxAge: TimeInterval,
        deriveFileRisks: Bool
    ) throws -> AgentSessionRegistrySnapshot {
        let loadedAt = registry.now()
        let key = [
            registry.fileURL.standardizedFileURL.path,
            deriveFileRisks.description,
            registry.staleLogInterval.description,
        ].joined(separator: "|")

        lock.lock()
        if let entry = entries[key], loadedAt.timeIntervalSince(entry.loadedAt) <= maxAge {
            lock.unlock()
            return entry.snapshot
        }
        lock.unlock()

        let snapshot = try registry.loadSnapshot(deriveFileRisks: deriveFileRisks)

        lock.lock()
        entries[key] = Entry(loadedAt: loadedAt, snapshot: snapshot)
        lock.unlock()
        return snapshot
    }
}

enum AgentSessionRegistryParser {
    private static let codexLogProofReadLimit = 1_048_576

    static func parseFixture(
        data: Data,
        baseURL: URL? = nil,
        now: Date = Date(),
        staleLogInterval: TimeInterval = 300,
        deriveFileRisks: Bool = true,
        fileManager: FileManager = .default,
        dirtyWorktreeChecker: @escaping (String) -> Bool = defaultDirtyWorktreeChecker,
        tmuxSessionChecker: @escaping (String) -> Bool = defaultTmuxSessionChecker
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
                fileManager: fileManager,
                dirtyWorktreeChecker: dirtyWorktreeChecker,
                tmuxSessionChecker: tmuxSessionChecker
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
            fileManager: fileManager,
            dirtyWorktreeChecker: dirtyWorktreeChecker,
            tmuxSessionChecker: tmuxSessionChecker
        )
    }

    static func compose(
        sessions: [AgentSession],
        generatedAt: Date? = nil,
        baseURL: URL? = nil,
        now: Date = Date(),
        staleLogInterval: TimeInterval = 300,
        deriveFileRisks: Bool = true,
        fileManager: FileManager = .default,
        dirtyWorktreeChecker: @escaping (String) -> Bool = defaultDirtyWorktreeChecker,
        tmuxSessionChecker: @escaping (String) -> Bool = defaultTmuxSessionChecker
    ) -> AgentSessionRegistrySnapshot {
        let sharedWorktrees = sharedWorktreeIdentities(sessions, baseURL: baseURL)
        let dirtyWorktrees = deriveFileRisks
            ? dirtyWorktreeIdentities(
                sessions,
                baseURL: baseURL,
                checker: dirtyWorktreeChecker
            )
            : []
        let riskContext = RiskDerivationContext(
            sharedWorktrees: sharedWorktrees,
            dirtyWorktrees: dirtyWorktrees,
            baseURL: baseURL,
            now: now,
            staleLogInterval: staleLogInterval,
            deriveFileRisks: deriveFileRisks,
            fileManager: fileManager,
            tmuxSessionChecker: tmuxSessionChecker
        )
        var derived = sessions.map { session in
            let fileProofStatus = contextAllowsFileProofDerivation(riskContext)
                ? derivedProofStatus(for: session, context: riskContext)
                : nil
            let proofStatus = strongestProofStatus(
                session.proofStatus,
                fileProofStatus
            )
            return session.withProofStatus(proofStatus).addingRiskFlags(
                derivedRiskFlags(
                    for: session.withProofStatus(proofStatus),
                    context: riskContext
                )
            )
        }
        derived = sessionsWithStaleChildRisk(derived)
        let roots = buildHierarchy(from: derived)
        let flat = roots.flatMap(\.flattened).map(\.session)
        let attributionLabels = attributionLabelsBySessionID(roots: roots)
        return AgentSessionRegistrySnapshot(
            generatedAt: generatedAt,
            sessions: flat,
            roots: roots,
            attributionLabelsBySessionID: attributionLabels,
            attributionLabelsByJoinKey: attributionLabelsByJoinKey(attributionLabels)
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

    private static func sharedWorktreeIdentities(_ sessions: [AgentSession], baseURL: URL?) -> Set<String> {
        let identities = sessions.compactMap { session -> String? in
            guard let identity = session.references.worktreeIdentity else { return nil }
            return normalizedWorktreeIdentity(identity, baseURL: baseURL)
        }
        var shared = Set<String>()
        for (index, identity) in identities.enumerated() {
            guard !shared.contains(identity) else { continue }
            if identities[(index + 1)...].contains(where: { pathsOverlap(identity, $0) }) {
                shared.insert(identity)
            }
        }
        return shared.union(identities.filter { identity in
            shared.contains(where: { pathsOverlap(identity, $0) })
        })
    }

    private static func dirtyWorktreeIdentities(
        _ sessions: [AgentSession],
        baseURL: URL?,
        checker: (String) -> Bool
    ) -> Set<String> {
        let identities = Set(sessions.compactMap(\.references.worktreeIdentity))
        return Set(identities.filter { identity in
            guard let url = resolvedURL(for: identity, baseURL: baseURL) else { return false }
            return checker(url.path)
        }.compactMap { normalizedWorktreeIdentity($0, baseURL: baseURL) })
    }

    private static func derivedRiskFlags(
        for session: AgentSession,
        context: RiskDerivationContext
    ) -> Set<AgentSessionRiskFlag> {
        var flags = Set<AgentSessionRiskFlag>()
        if let worktree = session.references.worktreeIdentity,
           context.sharedWorktrees.contains(normalizedWorktreeIdentity(worktree, baseURL: context.baseURL))
        {
            flags.insert(.sharedWorktree)
        }
        if let worktree = session.references.worktreeIdentity,
           context.dirtyWorktrees.contains(normalizedWorktreeIdentity(worktree, baseURL: context.baseURL))
        {
            flags.insert(.dirtyWorktree)
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
        if let modified,
           sessionHasLiveActivityHost(session, context: context),
           context.now.timeIntervalSince(modified) > context.staleLogInterval
        {
            flags.insert(.staleLog)
        }
        return flags
    }

    private static func sessionHasLiveActivityHost(
        _ session: AgentSession,
        context: RiskDerivationContext
    ) -> Bool {
        guard let tmuxSession = session.references.tmuxSession else { return true }
        return context.tmuxSessionChecker(tmuxSession)
    }

    private static func derivedProofStatus(
        for session: AgentSession,
        context: RiskDerivationContext
    ) -> AgentSessionProofStatus? {
        var status: AgentSessionProofStatus?
        if let finalReport = session.references.finalReport,
           let finalReportURL = resolvedURL(for: finalReport, baseURL: context.baseURL),
           context.fileManager.fileExists(atPath: finalReportURL.path)
        {
            status = strongestProofStatus(status, .finalReported)
        }

        guard let marker = session.references.lastPromptMarker,
              let logPath = session.references.codexLog,
              let logURL = resolvedURL(for: logPath, baseURL: context.baseURL),
              let logText = boundedCodexLogProofText(from: logURL, fileManager: context.fileManager),
              let markerRange = logText.range(of: marker)
        else {
            return status
        }

        let tail = String(logText[markerRange.upperBound...])
        status = strongestProofStatus(status, .promptDelivered)
        if codexLogTailShowsToolActivity(tail) {
            status = strongestProofStatus(status, .toolActive)
        }
        return status
    }

    private static func contextAllowsFileProofDerivation(_ context: RiskDerivationContext) -> Bool {
        context.deriveFileRisks
    }

    private static func boundedCodexLogProofText(from url: URL, fileManager: FileManager) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { return nil }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > UInt64(codexLogProofReadLimit) else {
            return try? String(contentsOf: url, encoding: .utf8)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = size - UInt64(codexLogProofReadLimit)
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func codexLogTailShowsToolActivity(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { return false }
            return jsonObjectShowsToolActivity(object)
        }
    }

    private static func jsonObjectShowsToolActivity(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if key == "recipient_name" { return true }
                if key == "type",
                   let string = value as? String,
                   ["function_call", "tool_call", "tool_use"].contains(string)
                {
                    return true
                }
                if jsonObjectShowsToolActivity(value) { return true }
            }
            return false
        }
        if let array = object as? [Any] {
            return array.contains(where: jsonObjectShowsToolActivity)
        }
        return false
    }

    private static func strongestProofStatus(
        _ lhs: AgentSessionProofStatus?,
        _ rhs: AgentSessionProofStatus?
    ) -> AgentSessionProofStatus {
        let lhs = lhs ?? .unverified
        let rhs = rhs ?? .unverified
        return proofRank(lhs) >= proofRank(rhs) ? lhs : rhs
    }

    private static func proofRank(_ status: AgentSessionProofStatus) -> Int {
        switch status {
        case .unverified: 0
        case .promptDelivered: 1
        case .toolActive: 2
        case .finalReported: 3
        case .validated: 4
        }
    }

    private static func resolvedURL(for path: String, baseURL: URL?) -> URL? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (baseURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(path)
    }

    private static func normalizedWorktreeIdentity(_ path: String, baseURL: URL?) -> String {
        guard let url = resolvedURL(for: path, baseURL: baseURL) else { return "" }
        return normalizedPath(url.standardizedFileURL.path)
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard standardized != "/" else { return standardized }
        return standardized.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if lhs == "/" || rhs == "/" { return lhs == "/" && rhs == "/" }
        return lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    static func defaultDirtyWorktreeChecker(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", expanded, "status", "--porcelain"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return !data.isEmpty
        } catch {
            return false
        }
    }

    static func defaultTmuxSessionChecker(_ session: String) -> Bool {
        let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "has-session", "-t", trimmed]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
        for requestSessionID in session.attribution.requestSessionIds {
            keys.append("request-session:\(requestSessionID)")
            keys.append("request-session:\(CLIProxyUsageRedactor.safeIdentifier(requestSessionID, prefix: "session"))")
        }
        return Array(Set(keys)).sorted()
    }

    private static func attributionLabelsByJoinKey(
        _ labelsBySessionID: [String: AgentUsageAttributionLabels]
    ) -> [String: AgentUsageAttributionLabels] {
        var labelsByJoinKey: [String: AgentUsageAttributionLabels] = [:]
        for labels in labelsBySessionID.values {
            for joinKey in labels.joinKeys where labelsByJoinKey[joinKey] == nil {
                labelsByJoinKey[joinKey] = labels
            }
        }
        return labelsByJoinKey
    }
}

private struct RegistryEnvelope: Decodable {
    let generatedAt: Date?
    let sessions: [SessionRecord]
}

private struct RiskDerivationContext {
    let sharedWorktrees: Set<String>
    let dirtyWorktrees: Set<String>
    let baseURL: URL?
    let now: Date
    let staleLogInterval: TimeInterval
    let deriveFileRisks: Bool
    let fileManager: FileManager
    let tmuxSessionChecker: (String) -> Bool
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
