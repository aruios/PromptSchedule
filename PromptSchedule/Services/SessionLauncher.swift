//
//  SessionLauncher.swift
//  PromptSchedule
//

import AppKit

/// Starts a new interactive Claude Code session in a terminal.
enum SessionLauncher {
    static var isITermInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    static var isTmuxInstalled: Bool {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Opens a new terminal window in `folder` running `claude`, optionally with a first prompt.
    static func launch(in folder: String, terminal: TerminalKind, firstPrompt: String?) async throws {
        var command = "cd \(shellQuoted(folder)) && "
        let claude = firstPrompt.map { "claude \(shellQuoted($0))" } ?? "claude"
        // tmux runs inside a new Terminal window so the session is visible straight away.
        command += terminal == .tmux ? "tmux new-session \(shellQuoted(claude))" : claude

        // The terminal's own shell runs the command, so ~/.zshrc PATH entries apply.
        let script: String
        switch terminal {
        case .iTerm:
            script = """
            on run argv
                tell application "iTerm2"
                    activate
                    set newWindow to (create window with default profile)
                    tell current session of newWindow to write text (item 1 of argv)
                end tell
            end run
            """
        case .terminal, .tmux, .unsupported:
            script = """
            on run argv
                tell application "Terminal"
                    activate
                    do script (item 1 of argv)
                end tell
            end run
            """
        }

        let result = try await Shell.run("/usr/bin/osascript", ["-e", script, command], timeout: 120)
        guard result.status == 0 else {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-1743") {
                throw ShellError.failed("Not allowed to control the terminal. Enable it in System Settings › Privacy & Security › Automation.")
            }
            throw ShellError.failed(message.isEmpty ? "Couldn't open the terminal." : message)
        }
    }

    /// Wraps a value in single quotes for the shell, escaping any single quotes inside.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
