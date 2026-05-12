import AppKit
import os
import SwiftUI

private let agentTreeLogger = Logger(subsystem: "app.muxy", category: "AgentTree")

struct AgentTreeView: View {
    let worktree: Worktree

    @Environment(\.agentSessionRegistry) private var registry
    @State private var roots: [AgentSessionNode] = []
    @State private var expansionState = AgentTreeExpansionState()
    @State private var knownExpandableSessionIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(roots) { node in
                AgentTreeNodeRow(
                    node: node,
                    depth: 0,
                    registryBaseURL: registry.fileURL.deletingLastPathComponent(),
                    expansionState: $expansionState
                )
            }
        }
        .padding(.vertical, roots.isEmpty ? 0 : UIMetrics.spacing1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent sessions for \(worktree.name)")
        .accessibilityHidden(roots.isEmpty)
        .task(id: AgentTreeWorktreeFilter.standardizedPath(worktree.path)) {
            await refreshLoop()
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            reloadSessions()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func reloadSessions() {
        let snapshot: AgentSessionRegistrySnapshot
        do {
            snapshot = try registry.loadCachedSnapshot()
        } catch {
            let errorDescription = String(describing: error)
            agentTreeLogger
                .error(
                    "Failed to load agent session registry: \(errorDescription, privacy: .public)"
                )
            roots = []
            expansionState = AgentTreeExpansionState()
            knownExpandableSessionIDs = []
            return
        }
        let filteredRoots = AgentTreeWorktreeFilter.nodes(
            in: snapshot.roots,
            matchingWorktreePath: worktree.path
        )
        let sessionCount = snapshot.sessions.count
        let rootCount = filteredRoots.count
        agentTreeLogger
            .debug(
                "Agent tree registry loaded sessions=\(sessionCount, privacy: .public) matches=\(rootCount, privacy: .public)"
            )
        expansionState.expandNewParents(in: filteredRoots, knownParentIDs: &knownExpandableSessionIDs)
        roots = filteredRoots
    }
}

private struct AgentTreeNodeRow: View {
    let node: AgentSessionNode
    let depth: Int
    let registryBaseURL: URL
    @Binding var expansionState: AgentTreeExpansionState

    @State private var hovered = false

    private var session: AgentSession { node.session }
    private var isExpanded: Bool { expansionState.isExpanded(node) }
    private var hasChildren: Bool { !node.children.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent

            if isExpanded {
                ForEach(node.children) { child in
                    AgentTreeNodeRow(
                        node: child,
                        depth: depth + 1,
                        registryBaseURL: registryBaseURL,
                        expansionState: $expansionState
                    )
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: UIMetrics.spacing2) {
            Color.clear.frame(width: CGFloat(depth) * AgentTreeLayout.rowIndent)
            roleIcon
            Text(AgentTreeDisplay.compactModelReasoningLabel(for: session))
                .font(.system(size: UIMetrics.fontMicro, weight: .semibold, design: .monospaced))
                .foregroundStyle(MuxyTheme.fgMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(AgentTreeDisplay.modelReasoningLabel(for: session))
            Text(AgentTreeDisplay.taskLabel(for: session))
                .font(.system(size: UIMetrics.fontBody))
                .foregroundStyle(MuxyTheme.fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIMetrics.spacing3)
        .frame(height: UIMetrics.scaled(22))
        .background(hovered ? MuxyTheme.hover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpandedIfNeeded() }
        .onHover { hovered = $0 }
        .contextMenu { contextMenuContent }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AgentTreeAccessibility.rowLabel(
            for: session,
            isExpanded: isExpanded,
            childCount: node.children.count
        ))
    }

    @ViewBuilder
    private var roleIcon: some View {
        if hasChildren {
            Button {
                toggleExpandedIfNeeded()
            } label: {
                roleIconImage
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(session.displayName)" : "Expand \(session.displayName)")
        } else {
            roleIconImage
        }
    }

    private var roleIconImage: some View {
        Image(systemName: session.role.sidebarIconName)
            .font(.system(size: UIMetrics.fontCaption, weight: .semibold))
            .foregroundStyle(session.role.sidebarTint)
            .frame(width: UIMetrics.iconSM)
            .contentShape(Rectangle())
    }

    private var contextMenuContent: some View {
        ForEach(openReferences, id: \.title) { reference in
            Button(reference.title) {
                agentTreeLogger
                    .info("Opening agent tree reference \(reference.title, privacy: .public): \(reference.url.path, privacy: .private)")
                NSWorkspace.shared.open(reference.url)
            }
        }
    }

    private var openReferences: [AgentTreeOpenReference] {
        [
            AgentTreeOpenReferenceValidator.reference(
                title: "Open Worktree",
                path: session.references.worktreeIdentity,
                baseURL: nil,
                kind: .directory
            ),
            AgentTreeOpenReferenceValidator.reference(
                title: "Open Codex Log",
                path: session.references.codexLog,
                baseURL: registryBaseURL,
                kind: .file
            ),
            AgentTreeOpenReferenceValidator.reference(
                title: "Open Final Report",
                path: session.references.finalReport,
                baseURL: registryBaseURL,
                kind: .file
            ),
        ].compactMap(\.self)
    }

    private func toggleExpandedIfNeeded() {
        guard hasChildren else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            expansionState.toggle(node)
        }
    }
}
