import AppKit
import Foundation

@MainActor
enum CLIAccessor {
    static func openProjectFromPath(
        _ path: String,
        appState: AppState,
        projectStore: ProjectStore,
        worktreeStore: WorktreeStore
    ) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return }

        if let existing = projectStore.projects.first(where: { $0.path == standardizedPath }),
           let primary = worktreeStore.primary(for: existing.id)
        {
            appState.selectProject(existing, worktree: primary)
            activateApp()
            return
        }

        let url = URL(fileURLWithPath: standardizedPath)
        let project = Project(
            name: url.lastPathComponent,
            path: standardizedPath,
            sortOrder: projectStore.projects.count
        )
        projectStore.add(project)
        worktreeStore.ensurePrimary(for: project)
        guard let primary = worktreeStore.primary(for: project.id) else { return }
        appState.selectProject(project, worktree: primary)
        activateApp()
    }

    private static func activateApp() {
        let app = NSApplication.shared
        guard app.isRunning else { return }
        app.activate(ignoringOtherApps: true)
    }

    static func installCLI() {
        guard let resourceURL = Bundle.appResources.url(
            forResource: "muxy-cli",
            withExtension: ""
        )
        else {
            alert(title: "CLI Not Found", body: "The CLI script was not found in the app bundle.")
            return
        }

        guard confirmInstall() else { return }

        let commandName = AppIdentity.cliCommandName
        if copyScript(from: resourceURL, to: "/usr/local/bin", commandName: commandName) {
            showInstalledAlert(commandName: commandName, label: "/usr/local/bin/\(commandName)", pathNote: "")
            return
        }

        Task.detached(priority: .userInitiated) {
            let success = runAdminInstall(resourceURL: resourceURL, commandName: commandName)
            await MainActor.run {
                if success {
                    showInstalledAlert(commandName: commandName, label: "/usr/local/bin/\(commandName)", pathNote: "")
                    return
                }
                if tryFallbackInstalls(resourceURL: resourceURL, commandName: commandName) { return }
                alert(
                    title: "CLI Installation Failed",
                    body: """
                    Could not install \(commandName) to /usr/local/bin or any fallback directory.

                    Try manually:
                      sudo cp "\(resourceURL.path)" /usr/local/bin/\(commandName)
                      sudo chmod +x /usr/local/bin/\(commandName)
                    """
                )
            }
        }
    }

    private static func copyScript(from resourceURL: URL, to binPath: String, commandName: String) -> Bool {
        let target = URL(fileURLWithPath: "\(binPath)/\(commandName)")
        let dir = URL(fileURLWithPath: binPath)
        if !FileManager.default.fileExists(atPath: binPath) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        do {
            try FileManager.default.copyItem(at: resourceURL, to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: FilePermissions.executable],
                ofItemAtPath: target.path
            )
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func runAdminInstall(resourceURL: URL, commandName: String) -> Bool {
        let quotedSource = ShellEscaper.escape(resourceURL.path)
        let quotedTarget = ShellEscaper.escape("/usr/local/bin/\(commandName)")
        let shellCommand = "mkdir -p /usr/local/bin && cp \(quotedSource) \(quotedTarget) && chmod +x \(quotedTarget)"
        let escapedForAppleScript = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    private static func tryFallbackInstalls(resourceURL: URL, commandName: String) -> Bool {
        let home = NSHomeDirectory()
        let fallbacks = [
            (path: "\(home)/bin", label: "~/bin/\(commandName)"),
            (path: "\(home)/.local/bin", label: "~/.local/bin/\(commandName)"),
        ]
        for fallback in fallbacks {
            guard copyScript(from: resourceURL, to: fallback.path, commandName: commandName) else {
                continue
            }
            let pathNote = "\n\nAdd to PATH:\n  export PATH=\"$PATH:\(fallback.path)\""
            showInstalledAlert(commandName: commandName, label: fallback.label, pathNote: pathNote)
            return true
        }
        return false
    }

    private static func showInstalledAlert(commandName: String, label: String, pathNote: String) {
        alert(
            title: "CLI Installed",
            body: "Installed to: \(label)\nRun '\(commandName) .' or '\(commandName) /path/to/project'\(pathNote)"
        )
    }

    private static func confirmInstall() -> Bool {
        let alert = NSAlert()
        let commandName = AppIdentity.cliCommandName
        alert.messageText = "Install \(AppIdentity.displayName) CLI?"
        alert.informativeText = """
        This will install the '\(commandName)' command-line tool to /usr/local/bin so you \
        can launch projects from your terminal (e.g. '\(commandName) .').

        If /usr/local/bin is not writable, you will be prompted for your \
        administrator password. If that is declined, \(AppIdentity.displayName) will fall back to \
        ~/bin or ~/.local/bin.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func alert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
