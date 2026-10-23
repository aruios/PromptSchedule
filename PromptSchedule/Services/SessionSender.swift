//
//  SessionSender.swift
//  PromptSchedule
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Delivers a prompt to a Claude Code session in the terminal that hosts it.
///
/// - Terminal.app / iTerm2: select the tab owning the session's tty (AppleScript),
///   then press ⌘V and Return from this app (bracketed paste keeps multi-line
///   prompts together). The keys are posted by PromptSchedule itself, so they
///   use PromptSchedule's own Accessibility permission.
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
            try await paste(text, tty: target.tty, selectScript: terminalSelect, app: "Terminal", bundleID: "com.apple.Terminal")
        case .iTerm:
            try await paste(text, tty: target.tty, selectScript: iTermSelect, app: "iTerm2", bundleID: "com.googlecode.iterm2")
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

    private static func paste(_ text: String, tty: String, selectScript: String, app: String, bundleID: String) async throws {
        // Check first, so a missing permission doesn't pull the terminal to the front for nothing.
        guard hasAccessibility() else {
            throw ShellError.failed("Keystrokes blocked. Enable PromptSchedule in System Settings › Privacy & Security › Accessibility, then quit and reopen PromptSchedule.")
        }

        // AppleScript only brings the right tab to the front; it needs Automation, not Accessibility.
        let script = """
        on run argv
            set targetTTY to item 1 of argv
            set found to false
            \(selectScript)
        end run
        """
        // Long timeout: the first send waits on the macOS Automation permission dialog.
        let result = try await Shell.run("/usr/bin/osascript", ["-e", script, tty], timeout: 120)
        guard result.status == 0 else {
            throw ShellError.failed(friendlyError(result.error, app: app))
        }
        defer { NSApp.activate() }

        // Keystrokes go to whichever app is frontmost, so make sure it's the terminal.
        guard await waitForFrontmost(bundleID) else {
            throw ShellError.failed("\(app) didn't come to the front, so the prompt wasn't typed.")
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer { restore(saved, to: pasteboard) }

        pressKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        // Let the terminal read the clipboard and Claude Code take the paste before submitting.
        try await Task.sleep(for: .milliseconds(500))
        pressKey(CGKeyCode(kVK_Return))
        try await Task.sleep(for: .milliseconds(200))
    }

    private static func waitForFrontmost(_ bundleID: String) async -> Bool {
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func pressKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
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
