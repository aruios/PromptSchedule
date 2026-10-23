//
//  SessionSender.swift
//  PromptSchedule
//

import Foundation

/// Delivers a prompt to a Claude Code session in the background: the terminal
/// is never brought to the front, and the clipboard and keyboard aren't used.
///
/// The prompt is written straight into the session's input, wrapped in
/// bracketed-paste markers so Claude Code treats a multi-line prompt as one
/// paste, followed by Return to submit it.
/// - Terminal.app: `do script … in <tab>` on the tab that owns the session's tty.
/// - iTerm2: `write text` on the session that owns the tty.
/// - tmux: `paste-buffer -p` into the pane, then `send-keys Enter`.
///
/// Only the Automation permission (to control the terminal app) is needed.
enum SessionSender {
    private static let pasteStart = "\u{1b}[200~"
    private static let pasteEnd = "\u{1b}[201~"

    static func send(_ text: String, to target: PromptTarget, via terminal: TerminalKind) async throws {
        guard await SessionScanner.isAlive(pid: target.pid, tty: target.tty) else {
            throw ShellError.failed("Session has ended (pid \(target.pid) is no longer on \(target.tty)).")
        }
        // An end marker inside the prompt would end the paste early.
        let safeText = text.replacingOccurrences(of: pasteEnd, with: "")
        switch terminal {
        case .terminal:
            try await runScript(terminalScript, tty: target.tty, text: pasteStart + safeText + pasteEnd, app: "Terminal")
        case .iTerm:
            try await runScript(iTermScript, tty: target.tty, text: pasteStart + safeText + pasteEnd, app: "iTerm2")
        case .tmux:
            try await sendToTmux(safeText, tty: target.tty)
        case .unsupported:
            throw ShellError.failed("This session runs in a terminal PromptSchedule can't control.")
        }
    }

    // MARK: - Terminal.app / iTerm2

    /// `do script` types the text plus Return into the tab without activating Terminal.
    private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        set payload to item 2 of argv
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        do script payload in t
                        return
                    end if
                end repeat
            end repeat
        end tell
        error "No Terminal tab found for " & targetTTY
    end run
    """

    /// `write text` sends the text plus Return to the session without focusing it.
    private static let iTermScript = """
    on run argv
        set targetTTY to item 1 of argv
        set payload to item 2 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            tell s to write text payload
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        error "No iTerm2 session found for " & targetTTY
    end run
    """

    private static func runScript(_ script: String, tty: String, text: String, app: String) async throws {
        // Long timeout: the first send waits on the macOS Automation permission dialog.
        let result = try await Shell.run("/usr/bin/osascript", ["-e", script, tty, text], timeout: 120)
        guard result.status == 0 else {
            throw ShellError.failed(friendlyError(result.error, app: app))
        }
    }

    private static func friendlyError(_ raw: String, app: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-1743") {
            return "Not allowed to control \(app). Enable it in System Settings › Privacy & Security › Automation."
        }
        return message.isEmpty ? "osascript failed" : message
    }

    // MARK: - tmux

    private static func sendToTmux(_ text: String, tty: String) async throws {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw ShellError.failed("tmux not found in /opt/homebrew/bin or /usr/local/bin.") }

        // Each line is "<pane tty> <pane id>", e.g. "/dev/ttys012 %3".
        let panes = try await Shell.run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        var pane: String?
        for line in panes.output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, String(fields[0]) == tty {
                pane = String(fields[1])
                break
            }
        }
        guard let pane else { throw ShellError.failed("No tmux pane found for \(tty).") }

        let buffer = "promptschedule"
        for arguments in [
            ["set-buffer", "-b", buffer, "--", text],
            ["paste-buffer", "-p", "-d", "-b", buffer, "-t", pane],
        ] {
            let result = try await Shell.run(tmux, arguments)
            guard result.status == 0 else { throw ShellError.failed("tmux: \(result.error)") }
        }
        // Give Claude Code a moment to take the paste before submitting it.
        try await Task.sleep(for: .milliseconds(400))
        _ = try await Shell.run(tmux, ["send-keys", "-t", pane, "Enter"])
    }
}
