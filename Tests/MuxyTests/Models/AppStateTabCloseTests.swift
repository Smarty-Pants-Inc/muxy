import Foundation
import Testing

@testable import Muxy

@Suite("AppState tab closing")
@MainActor
struct AppStateTabCloseTests {
    @Test("confirming close for running last tab defers project close prompt")
    func confirmingRunningLastTabDefersLastTabPrompt() async throws {
        let projectID = UUID()
        let worktreeID = UUID()
        let path = "/tmp/test"
        let terminalViews = TerminalViewRemovingStub(needsConfirmation: true)
        let appState = AppState(
            selectionStore: SelectionStoreStub(),
            terminalViews: terminalViews,
            workspacePersistence: WorkspacePersistenceStub()
        )
        let area = TabArea(projectPath: path)
        let tab = try #require(area.tabs.first)
        let paneID = try #require(tab.content.pane?.id)
        terminalViews.confirmingPaneIDs = [paneID]
        let key = WorktreeKey(projectID: projectID, worktreeID: worktreeID)
        appState.activeProjectID = projectID
        appState.activeWorktreeID[projectID] = worktreeID
        appState.workspaceRoots[key] = .tabArea(area)
        appState.focusedAreaID[key] = area.id

        let previousKeepOpen = UserDefaults.standard.object(
            forKey: ProjectLifecyclePreferences.keepOpenWhenNoTabsKey
        )
        ProjectLifecyclePreferences.keepOpenWhenNoTabs = false
        defer {
            if let previousKeepOpen {
                UserDefaults.standard.set(previousKeepOpen, forKey: ProjectLifecyclePreferences.keepOpenWhenNoTabsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ProjectLifecyclePreferences.keepOpenWhenNoTabsKey)
            }
        }

        appState.closeTab(tab.id, areaID: area.id, projectID: projectID)
        #expect(appState.pendingProcessTabClose == .init(projectID: projectID, areaID: area.id, tabID: tab.id))

        appState.confirmCloseRunningTab()

        #expect(appState.pendingProcessTabClose == nil)
        #expect(appState.pendingLastTabClose == nil)

        try await Task.sleep(for: .milliseconds(10))

        #expect(appState.pendingLastTabClose == .init(projectID: projectID, areaID: area.id, tabID: tab.id))
    }
}

private final class SelectionStoreStub: ActiveProjectSelectionStoring {
    private var activeProjectID: UUID?
    private var activeWorktreeIDs: [UUID: UUID] = [:]

    func loadActiveProjectID() -> UUID? { activeProjectID }

    func saveActiveProjectID(_ id: UUID?) { activeProjectID = id }

    func loadActiveWorktreeIDs() -> [UUID: UUID] { activeWorktreeIDs }

    func saveActiveWorktreeIDs(_ ids: [UUID: UUID]) { activeWorktreeIDs = ids }
}

@MainActor
private final class TerminalViewRemovingStub: TerminalViewRemoving {
    var confirmingPaneIDs: Set<UUID> = []
    private let needsConfirmation: Bool

    init(needsConfirmation: Bool) {
        self.needsConfirmation = needsConfirmation
    }

    func removeView(for _: UUID) {}

    func needsConfirmQuit(for paneID: UUID) -> Bool {
        needsConfirmation && confirmingPaneIDs.contains(paneID)
    }
}

private final class WorkspacePersistenceStub: WorkspacePersisting {
    var snapshots: [WorkspaceSnapshot] = []

    func loadWorkspaces() throws -> [WorkspaceSnapshot] { snapshots }

    func saveWorkspaces(_ workspaces: [WorkspaceSnapshot]) throws {
        snapshots = workspaces
    }
}
