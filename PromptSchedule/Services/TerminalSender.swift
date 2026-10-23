//
//  TerminalSender.swift
//  PromptSchedule
//

import AppKit
import ApplicationServices

/// Delivers a prompt to a Claude Code session by pasting it into the
/// Terminal.app tab that owns the session's tty and pressing Return.
///
/// Pasting (rather than typing) uses Terminal's bracketed paste, so Claude Code
/// receives multi-line prompts as one message instead of submitting each line.
enum TerminalSender {
    private static let script = """
    on run argv
        set targetTTY to item 1 of argv
        set found to false
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
        delay 0.3
        tell application "System Events"
            tell process "Terminal" to set frontmost to true
            keystroke "v" using command down
            delay 0.5
            key code 36
        end tell
        delay 0.2
    end run
    """

    /// True when the app may send keystrokes; pass `prompt: true` to show the system dialog.
    static func hasAccessibility(prompt: Bool = false) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func send(_ text: String, to target: PromptTarget) async throws {
        guard await SessionScanner.isAlive(pid: target.pid, tty: target.tty) else {
            throw ShellError.failed("Session has ended (pid \(target.pid) is no longer on \(target.tty)).")
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer {
            restore(saved, to: pasteboard)
            NSApp.activate()
        }

        let result = try await Shell.run("/usr/bin/osascript", ["-e", script, target.tty])
        guard result.status == 0 else {
            throw ShellError.failed(friendlyError(result.error))
        }
    }

    private static func friendlyError(_ raw: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("-1743") {
            return "Not allowed to control Terminal. Enable it in System Settings › Privacy & Security › Automation."
        }
        if message.contains("-1719") || message.contains("-25211") || message.contains("assistive access") {
            return "Keystrokes blocked. Enable PromptSchedule in System Settings › Privacy & Security › Accessibility."
        }
        return message.isEmpty ? "osascript failed" : message
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
