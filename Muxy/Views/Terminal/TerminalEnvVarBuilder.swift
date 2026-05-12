import Foundation

@MainActor
enum TerminalEnvVarBuilder {
    private static let inheritedTerminalEnvironmentKeysToScrub = [
        "NO_COLOR",
        "TERM",
        "TERMINFO",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "COLORTERM",
    ]

    static func scrubInheritedTerminalEnvironment() {
        for key in inheritedTerminalEnvironmentKeysToScrub {
            unsetenv(key)
        }
    }

    static func build(paneID: UUID, worktreeKey key: WorktreeKey) -> [(key: String, value: String)] {
        var vars: [(key: String, value: String)] = [
            (key: "MUXY_PANE_ID", value: paneID.uuidString),
            (key: "MUXY_PROJECT_ID", value: key.projectID.uuidString),
            (key: "MUXY_WORKTREE_ID", value: key.worktreeID.uuidString),
            (key: "MUXY_SOCKET_PATH", value: NotificationSocketServer.socketPath),
            (key: "TERM", value: "xterm-ghostty"),
            (key: "COLORTERM", value: "truecolor"),
            (key: "CLICOLOR", value: "1"),
        ]
        if let hookPath = MuxyNotificationHooks.hookScriptPath {
            vars.append((key: "MUXY_HOOK_SCRIPT", value: hookPath))
        }
        return vars
    }
}
