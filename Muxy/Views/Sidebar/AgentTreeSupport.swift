import Foundation
import SwiftUI

enum AgentTreeFeatureGate {
    static let defaultsKey = "smarty.agentTree.enabled"
    static let environmentKey = "SMARTY_CODE_AGENT_TREE_ENABLED"

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let environmentValue = environment[environmentKey], let parsed = parseBool(environmentValue) {
            return parsed
        }
        guard defaults.object(forKey: defaultsKey) != nil else { return false }
        return defaults.bool(forKey: defaultsKey)
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1",
             "true",
             "yes",
             "on",
             "enabled": true
        case "0",
             "false",
             "no",
             "off",
             "disabled": false
        default: nil
        }
    }
}

extension EnvironmentValues {
    @Entry var agentSessionRegistry = AgentSessionRegistry(fileURL: AgentTreeRegistryLocation.defaultURL)
}

enum AgentTreeSidebarAttachment {
    static func shouldAttach(isWideSidebar: Bool, featureEnabled: Bool) -> Bool {
        isWideSidebar && featureEnabled
    }
}

@MainActor
enum AgentTreeLayout {
    static var rowIndent: CGFloat { UIMetrics.spacing2 }
}

enum AgentTreeDisplay {
    static let fixtureModel = "gpt5.5"
    static let fixtureReasoning = "xhigh"
    static let fixtureModelShort = "5.5"

    static func modelReasoningLabel(for _: AgentSession) -> String {
        "\(fixtureModel) · \(fixtureReasoning)"
    }

    static func compactModelReasoningLabel(for _: AgentSession) -> String {
        "\(fixtureModelShort)/\(fixtureReasoning.prefix(2))"
    }

    static func taskLabel(for session: AgentSession, maxWords: Int = 4) -> String {
        let roleTrimmed = removingRoleSuffix(from: session.displayName, role: session.role)
        let words = roleTrimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > maxWords else { return roleTrimmed }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    private static func removingRoleSuffix(from title: String, role: AgentSessionRole) -> String {
        var label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return title }

        let suffixes = roleSuffixes(for: role)
        for suffix in suffixes {
            let pattern = "\\s+\(NSRegularExpression.escapedPattern(for: suffix))$"
            let stripped = label.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            if stripped != label, !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                label = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return label
    }

    private static func roleSuffixes(for role: AgentSessionRole) -> [String] {
        switch role {
        case .architect:
            ["architect"]
        case .conductor:
            ["conductor"]
        case .orchestrator:
            ["orchestrator"]
        case .subagent:
            ["subagent", "sub-agent", "worker", "agent"]
        case .unknown:
            ["architect", "conductor", "orchestrator", "subagent", "sub-agent", "worker", "agent"]
        }
    }
}

enum AgentTreeReferenceResolver {
    static func fileURL(for path: String, baseURL: URL?) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return (baseURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }
}

@MainActor
enum AgentTreeAccessibility {
    static func rowLabel(
        for session: AgentSession,
        isExpanded: Bool,
        childCount: Int
    ) -> String {
        var parts = [
            "Agent session \(AgentTreeDisplay.taskLabel(for: session))",
            "Role: \(session.role.displayName)",
            "Model: \(AgentTreeDisplay.modelReasoningLabel(for: session))",
        ]
        if childCount == 1 {
            parts.append("1 child session")
            parts.append(isExpanded ? "Expanded" : "Collapsed")
        } else if childCount > 1 {
            parts.append("\(childCount) child sessions")
            parts.append(isExpanded ? "Expanded" : "Collapsed")
        }
        return parts.joined(separator: ". ")
    }
}

enum AgentTreeWorktreeFilter {
    static func nodes(
        in roots: [AgentSessionNode],
        matchingWorktreePath worktreePath: String
    ) -> [AgentSessionNode] {
        let target = standardizedPath(worktreePath)
        guard !target.isEmpty else { return [] }
        return roots.compactMap { filteredNode($0, target: target) }
    }

    static func standardizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let standardized = if expanded.hasPrefix("/") {
            URL(fileURLWithPath: expanded).standardizedFileURL.path
        } else {
            expanded
        }
        guard standardized != "/" else { return standardized }
        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? standardized : standardized.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private static func filteredNode(_ node: AgentSessionNode, target: String) -> AgentSessionNode? {
        let children = node.children.compactMap { filteredNode($0, target: target) }
        guard sessionMatches(node.session, target: target) || !children.isEmpty else { return nil }
        return AgentSessionNode(session: node.session, children: children)
    }

    private static func sessionMatches(_ session: AgentSession, target: String) -> Bool {
        [session.references.worktreePath, session.references.cwd]
            .compactMap(\.self)
            .contains { candidateContainsWorktree($0, target: target) }
    }

    private static func candidateContainsWorktree(_ candidate: String, target: String) -> Bool {
        let path = standardizedPath(candidate)
        guard !path.isEmpty else { return false }
        if path == target { return true }
        if target == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(target + "/")
    }
}

@MainActor
extension AgentSessionRole {
    var sidebarIconName: String {
        switch self {
        case .architect: "building.columns"
        case .conductor: "target"
        case .orchestrator: "gearshape"
        case .subagent: "circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var sidebarTint: Color {
        switch self {
        case .architect: MuxyTheme.accent
        case .conductor: MuxyTheme.accent
        case .orchestrator: MuxyTheme.fg
        case .subagent: MuxyTheme.fgMuted
        case .unknown: MuxyTheme.fgDim
        }
    }
}

enum AgentTreeReferenceKind {
    case file
    case directory
}

struct AgentTreeOpenReference: Equatable {
    let title: String
    let url: URL
}

enum AgentTreeOpenReferenceValidator {
    static func reference(
        title: String,
        path: String?,
        baseURL: URL?,
        kind: AgentTreeReferenceKind,
        fileManager: FileManager = .default
    ) -> AgentTreeOpenReference? {
        guard let path, let url = AgentTreeReferenceResolver.fileURL(for: path, baseURL: baseURL) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        switch kind {
        case .directory:
            guard isDirectory.boolValue else { return nil }
        case .file:
            guard !isDirectory.boolValue else { return nil }
        }
        return AgentTreeOpenReference(title: title, url: url)
    }
}

struct AgentTreeExpansionState: Equatable {
    private(set) var expandedIDs: Set<String>

    init(expandedIDs: Set<String> = []) {
        self.expandedIDs = expandedIDs
    }

    func isExpanded(_ node: AgentSessionNode) -> Bool {
        node.children.isEmpty || expandedIDs.contains(node.id)
    }

    mutating func toggle(_ node: AgentSessionNode) {
        guard !node.children.isEmpty else { return }
        if expandedIDs.contains(node.id) {
            expandedIDs.remove(node.id)
        } else {
            expandedIDs.insert(node.id)
        }
    }

    mutating func expandNewParents(in roots: [AgentSessionNode], knownParentIDs: inout Set<String>) {
        let parentIDs = Self.expandableIDs(in: roots)
        expandedIDs.formUnion(parentIDs.subtracting(knownParentIDs))
        knownParentIDs.formUnion(parentIDs)
    }

    static func expandableIDs(in roots: [AgentSessionNode]) -> Set<String> {
        Set(roots.flatMap(\.flattened).filter { !$0.children.isEmpty }.map(\.id))
    }
}
