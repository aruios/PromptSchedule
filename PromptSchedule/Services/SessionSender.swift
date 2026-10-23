//
//  SessionSender.swift
//  PromptSchedule
//

import AppKit
import ApplicationServices

/// Delivers a prompt to a Claude Code session in the terminal that hosts it.
///
/// - Terminal.app / iTerm2: select the tab owning the session's tty, paste the
///   prompt (bracketed paste keeps multi-line prompts together) and press Return.
/// - tmux: paste straight into the pane with `paste-buffer -p`; no focus change
///   or Accessibility permission needed.
enum SessionSender {
    /// True when the app may send keystrokes; pass `prompt: true` to show the system dialog.
    static func hasAccessibility(prompt: Bool = false) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func send(_ text: String, to target: PromptTarget, via terminal: TerminalKind) async throws {
        guard await SessionScanner.isAlive(pid: target.pid, tty: target.tty) else {
            throw ShellError.failed("Session has ended (pid \(target.pid) is no longer on \(target.tty)).")
        }
        switch terminal {
        case .terminal:
            try await paste(text, tty: target.tty, selectScript: terminalSelect, processName: "Terminal")
        case .iTerm:
            try await paste(text, tty: target.tty, selectScript: iTermSelect, processName: "iTerm2")
        case .tmux:
            try await sendToTmux(text, tty: target.tty)
        case .unsupported:
            throw ShellError.failed("This session runs in a terminal PromptSchedule can't control.")
        }
    }

    // MARK: - Terminal.app / iTerm2

    private static let terminalSelect = """
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is targetTTY then
                    set selected of t to true
                    set index of w to 1
                    set found to true
                    exit repeat
                end if
            end repeat
            if found then exit repeat
        end repeat
        if not found then error "No Terminal tab found for " & targetTTY
        activate
    end tell
    """

    private static let iTermSelect = """
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is targetTTY then
                        select w
                        select t
                        select s
                        set found to true
                        exit repeat
                    end if
                end repeat
                if found then exit repeat
            end repeat
            if found then exit repeat
        end repeat
        if not found then error "No iTerm2 session found for " & targetTTY
        activate
    end tell
    """

    private static func paste(_ text: String, tty: String, selectScript: String, processName: String) async throws {
        let script = """
        on run argv
            set targetTTY to item 1 of argv
            set found to false
            \(selectScript)
            delay 0.3
            tell application "System Events"
                tell process "\(processName)" to set frontmost to true
                keystroke "v" using command down
                delay 0.5
                key code 36
            end tell
            delay 0.2
        end run
        """

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer {
            restore(saved, to: pasteboard)
            NSApp.activate()
        }

        let result = try await Shell.run("/usr/bin/osascript", ["-e", script, tty])
        guard result.status == 0 else {
            throw ShellError.failed(friendlyError(result.error, app: processName))
        }
    }

    private static func friendlyError(_ raw: String, app: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-1743") {
            return "Not allowed to control \(app). Enable it in System Settings › Privacy & Security › Automation."
        }
        if message.contains("-1719") || message.contains("-25211") || message.contains("assistive access") {
            return "Keystrokes blocked. Enable PromptSchedule in System Settings › Privacy & Security › Accessibility."
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

    // MARK: - Clipboard preservation

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
