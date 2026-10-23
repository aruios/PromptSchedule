//
//  ClaudeHooks.swift
//  PromptSchedule
//

import Foundation

/// Optional Claude Code hooks (Premium) that tell PromptSchedule the moment a
/// session finishes a turn (`Stop`) or waits for permission (`Notification`).
///
/// The hook command appends the event JSON Claude Code passes on stdin to a file
/// in PromptSchedule's Application Support folder; the app reads new lines on
/// each tick. Without the hooks, completion is detected from transcripts alone.
enum ClaudeHooks {
    struct Event {
        var name: String
        var sessionId: String
        var message: String?
        /// When the app read the event (hooks don't include a time).
        var receivedAt: Date
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var eventsURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("PromptSchedule/hook-events.jsonl")
    }

    nonisolated private static let marker = "PromptSchedule/hook-events.jsonl"
    private static let events = ["Stop", "Notification"]

    /// Newlines inside the JSON are formatting only, so they're dropped to keep one event per line.
    private static let command =
        #"mkdir -p "$HOME/Library/Application Support/PromptSchedule" && { tr -d '\n'; echo; } >> "$HOME/Library/Application Support/PromptSchedule/hook-events.jsonl""#

    // MARK: - Install / remove

    static func isInstalled() -> Bool {
        guard let hooks = readSettings()?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { contains(hooks[$0]) }
    }

    /// Adds the hooks to ~/.claude/settings.json, keeping everything else.
    /// A backup is written next to it first.
    static func install() throws {
        var settings = readSettings() ?? [:]
        try backup()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events where !contains(hooks[event]) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    static func uninstall() throws {
        guard var settings = readSettings(), var hooks = settings["hooks"] as? [String: Any] else { return }
        try backup()
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                var group = group
                let entries = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                if entries.isEmpty { return nil }
                group["hooks"] = entries
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try write(settings)
    }

    nonisolated private static func contains(_ groups: Any?) -> Bool {
        (groups as? [[String: Any]])?.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) ?? false
        } ?? false
    }

    nonisolated private static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(marker) ?? false
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func backup() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.promptschedule-backup")
        try? fileManager.removeItem(at: backupURL)
        try fileManager.copyItem(at: settingsURL, to: backupURL)
    }

    private static func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Events

    private static var readOffset: UInt64?

    /// Events appended since the last call. The first call skips older events,
    /// so history from before launch isn't mistaken for new turns.
    static func readNewEvents() -> [Event] {
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        guard let offset = readOffset, offset <= end else {
            readOffset = end
            return []
        }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        // Only consume complete lines; a partial last line is read next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        readOffset = offset + UInt64(lastNewline + 1)

        let now = Date()
        let events = String(decoding: data[...lastNewline], as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> Event? in
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let name = json["hook_event_name"] as? String,
                      let sessionId = json["session_id"] as? String
                else { return nil }
                return Event(name: name, sessionId: sessionId, message: json["message"] as? String, receivedAt: now)
            }

        // Keep the file small: start over once everything is read and it's large.
        if end > 2 * 1024 * 1024, readOffset == end {
            try? Data().write(to: eventsURL)
            readOffset = 0
        }
        return events
    }
}
