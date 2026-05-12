import Foundation
import Testing

@testable import Muxy

@Suite("TerminalEnvVarBuilder")
@MainActor
struct TerminalEnvVarBuilderTests {
    @Test("terminal environment preserves color even when app was launched from a no-color shell")
    func terminalColorEnvironment() {
        let paneID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()
        let vars = Dictionary(
            uniqueKeysWithValues: TerminalEnvVarBuilder.build(
                paneID: paneID,
                worktreeKey: WorktreeKey(projectID: projectID, worktreeID: worktreeID)
            )
        )

        #expect(vars["MUXY_PANE_ID"] == paneID.uuidString)
        #expect(vars["MUXY_PROJECT_ID"] == projectID.uuidString)
        #expect(vars["MUXY_WORKTREE_ID"] == worktreeID.uuidString)
        #expect(vars["TERM"] == "xterm-ghostty")
        #expect(vars["COLORTERM"] == "truecolor")
        #expect(vars["CLICOLOR"] == "1")
        #expect(vars["NO_COLOR"] == nil)
    }
}
