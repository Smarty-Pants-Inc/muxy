import Foundation
import Testing

@testable import Muxy

@Suite("AgentTreeView")
struct AgentTreeViewTests {
    @Test("filters registry hierarchy while preserving matching ancestors")
    func filtersRegistryHierarchyForWorktree() throws {
        let fixture = """
        {
          "sessions": [
            {
              "id": "conductor",
              "role": "conductor",
              "title": "Roadmap conductor",
              "status": "running",
              "proof_status": "tool_active",
              "cwd": "/repo"
            },
            {
              "id": "orchestrator",
              "parent_id": "conductor",
              "role": "orchestrator",
              "title": "Track 10",
              "status": "ready",
              "proof_status": "prompt_delivered",
              "worktree_path": "/repo-track-10"
            },
            {
              "id": "worker",
              "parent_id": "orchestrator",
              "role": "worker",
              "title": "Sidebar worker",
              "status": "complete",
              "proof_status": "validated",
              "cwd": "/repo-track-10/src"
            }
          ]
        }
        """
        let snapshot = try AgentSessionRegistryParser.parseFixture(
            data: Data(fixture.utf8),
            deriveFileRisks: false
        )

        let filtered = AgentTreeWorktreeFilter.nodes(in: snapshot.roots, matchingWorktreePath: "/repo-track-10")

        #expect(filtered.map(\.id) == ["conductor"])
        #expect(filtered.first?.children.map(\.id) == ["orchestrator"])
        #expect(filtered.first?.children.first?.children.map(\.id) == ["worker"])
    }

    @Test("does not leak sibling worktree children into a parent worktree row")
    func excludesSiblingWorktrees() {
        let child = AgentSessionNode(
            session: AgentSession(
                id: "child",
                parentID: "conductor",
                role: .orchestrator,
                references: AgentSessionReferences(worktreePath: "/repo-feature")
            ),
            children: []
        )
        let conductor = AgentSessionNode(
            session: AgentSession(
                id: "conductor",
                role: .conductor,
                references: AgentSessionReferences(cwd: "/repo")
            ),
            children: [child]
        )

        let filtered = AgentTreeWorktreeFilter.nodes(in: [conductor], matchingWorktreePath: "/repo")

        #expect(filtered.map(\.id) == ["conductor"])
        #expect(filtered.first?.children.isEmpty == true)
    }

    @Test("matches child paths inside the selected worktree")
    func matchesNestedCwd() {
        let session = AgentSessionNode(
            session: AgentSession(
                id: "nested",
                role: .subagent,
                references: AgentSessionReferences(cwd: "/repo/worktree/Sources")
            ),
            children: []
        )

        let filtered = AgentTreeWorktreeFilter.nodes(in: [session], matchingWorktreePath: "/repo/worktree/")

        #expect(filtered.map(\.id) == ["nested"])
    }

    @Test("keeps empty worktree rows quiet")
    func emptyWorktreeReturnsNoNodes() {
        let session = AgentSessionNode(
            session: AgentSession(
                id: "elsewhere",
                role: .subagent,
                references: AgentSessionReferences(cwd: "/elsewhere")
            ),
            children: []
        )

        let filtered = AgentTreeWorktreeFilter.nodes(in: [session], matchingWorktreePath: "/repo")

        #expect(filtered.isEmpty)
    }

    @Test("registry location uses milestone default and environment override")
    func registryLocation() {
        #expect(AgentTreeRegistryLocation.url(environment: [:]).path == AgentTreeRegistryLocation.defaultPath)
        #expect(AgentTreeRegistryLocation.url(environment: [AgentTreeRegistryLocation.environmentKey: "  "]).path == AgentTreeRegistryLocation.defaultPath)

        let override = "~/Library/Application Support/Smarty Code/agent-sessions.json"
        let expected = NSString(string: override).expandingTildeInPath
        #expect(AgentTreeRegistryLocation.url(environment: [AgentTreeRegistryLocation.environmentKey: override]).path == expected)
    }

    @Test("sidebar attachment requires wide sidebar and enabled feature")
    @MainActor
    func sidebarAttachmentRequiresWideEnabledSidebar() {
        let wide = SidebarLayout.isWide(expanded: true, expandedStyle: .wide)
        let expandedIconRail = SidebarLayout.isWide(expanded: true, expandedStyle: .icons)
        let collapsedWidePreference = SidebarLayout.isWide(expanded: false, expandedStyle: .wide)

        #expect(AgentTreeSidebarAttachment.shouldAttach(isWideSidebar: wide, featureEnabled: true))
        #expect(!AgentTreeSidebarAttachment.shouldAttach(isWideSidebar: expandedIconRail, featureEnabled: true))
        #expect(!AgentTreeSidebarAttachment.shouldAttach(isWideSidebar: collapsedWidePreference, featureEnabled: true))
        #expect(!AgentTreeSidebarAttachment.shouldAttach(isWideSidebar: wide, featureEnabled: false))
    }

    @Test("feature gate is off by default and can be enabled by defaults or environment")
    func featureGate() throws {
        let suiteName = "AgentTreeViewTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!AgentTreeFeatureGate.isEnabled(defaults: defaults, environment: [:]))

        defaults.set(true, forKey: AgentTreeFeatureGate.defaultsKey)
        #expect(AgentTreeFeatureGate.isEnabled(defaults: defaults, environment: [:]))
        #expect(!AgentTreeFeatureGate.isEnabled(defaults: defaults, environment: [AgentTreeFeatureGate.environmentKey: "false"]))
        #expect(AgentTreeFeatureGate.isEnabled(defaults: defaults, environment: [AgentTreeFeatureGate.environmentKey: "1"]))
    }

    @Test("validates local open references by existence and expected type")
    func validatesOpenReferenceTypes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTreeViewTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let log = tempDir.appendingPathComponent("codex.jsonl")
        try "{}\n".write(to: log, atomically: true, encoding: .utf8)

        let relativeLog = AgentTreeOpenReferenceValidator.reference(
            title: "Open Codex Log",
            path: "codex.jsonl",
            baseURL: tempDir,
            kind: .file
        )
        #expect(relativeLog?.url == log.standardizedFileURL)

        let worktree = AgentTreeOpenReferenceValidator.reference(
            title: "Open Worktree",
            path: tempDir.path,
            baseURL: nil,
            kind: .directory
        )
        #expect(worktree?.url == tempDir.standardizedFileURL)

        #expect(AgentTreeOpenReferenceValidator.reference(
            title: "Open Worktree",
            path: log.path,
            baseURL: nil,
            kind: .directory
        ) == nil)
        #expect(AgentTreeOpenReferenceValidator.reference(
            title: "Open Codex Log",
            path: tempDir.path,
            baseURL: nil,
            kind: .file
        ) == nil)
        #expect(AgentTreeOpenReferenceValidator.reference(
            title: "Open Codex Log",
            path: "missing.jsonl",
            baseURL: tempDir,
            kind: .file
        ) == nil)
    }

    @Test("expansion state collapses and expands hierarchy parents")
    func expansionStateTogglesParents() {
        let child = AgentSessionNode(
            session: AgentSession(id: "child", role: .subagent),
            children: []
        )
        let parent = AgentSessionNode(
            session: AgentSession(id: "parent", role: .conductor),
            children: [child]
        )
        var known: Set<String> = []
        var state = AgentTreeExpansionState()

        state.expandNewParents(in: [parent], knownParentIDs: &known)
        #expect(state.isExpanded(parent))
        #expect(state.isExpanded(child))

        state.toggle(parent)
        #expect(!state.isExpanded(parent))

        state.toggle(parent)
        #expect(state.isExpanded(parent))
    }

    @Test("display helpers keep agent rows compact")
    func displayHelpersKeepRowsCompact() {
        let conductor = AgentSession(id: "conductor", role: .conductor, title: "Roadmap conductor")
        let orchestrator = AgentSession(id: "orchestrator", role: .orchestrator, title: "Navigation + Usage orchestrator")
        let worker = AgentSession(id: "worker", role: .subagent, title: "CLIProxyAPI proof worker")
        let long = AgentSession(id: "long", role: .subagent, title: "Investigate file tree row rendering polish worker")

        #expect(AgentTreeDisplay.taskLabel(for: conductor) == "Roadmap")
        #expect(AgentTreeDisplay.taskLabel(for: orchestrator) == "Navigation + Usage")
        #expect(AgentTreeDisplay.taskLabel(for: worker) == "CLIProxyAPI proof")
        #expect(AgentTreeDisplay.taskLabel(for: long) == "Investigate file tree row…")
        #expect(AgentTreeDisplay.modelReasoningLabel(for: worker) == "gpt5.5 · xhigh")
        #expect(AgentTreeDisplay.compactModelReasoningLabel(for: worker) == "5.5/xh")
    }

    @Test("accessibility labels describe compact agent rows")
    @MainActor
    func accessibilityLabelsDescribeCompactAgentRows() {
        let session = AgentSession(
            id: "orchestrator",
            role: .orchestrator,
            title: "Navigation orchestrator",
            status: .running,
            proofStatus: .toolActive,
            riskFlags: [.sharedWorktree, .dirtyWorktree]
        )

        let expanded = AgentTreeAccessibility.rowLabel(
            for: session,
            isExpanded: true,
            childCount: 2
        )
        let collapsed = AgentTreeAccessibility.rowLabel(
            for: session,
            isExpanded: false,
            childCount: 1
        )

        #expect(expanded == "Agent session Navigation. Role: Orchestrator. Model: gpt5.5 · xhigh. 2 child sessions. Expanded")
        #expect(collapsed.contains("1 child session. Collapsed"))
    }
}
