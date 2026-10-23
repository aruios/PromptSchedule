//
//  TranscriptReader.swift
//  PromptSchedule
//

import Foundation

/// Reads Claude Code transcripts (`~/.claude/projects/<folder>/<sessionId>.jsonl`)
/// to find out how Claude's turn on a prompt we sent went.
///
/// Transcripts are Claude Code internals, so parsing is defensive: unknown
/// lines are skipped and anything unexpected just means "not finished yet".
nonisolated enum TranscriptReader {
    /// What the transcript shows about the turn that started with our prompt.
    struct Turn: Equatable {
        /// Our prompt reached Claude (as a message, or in Claude's own queue).
        var promptSeen = false
        /// Claude ended its turn (`end_turn` or a `turn_duration` entry).
        var finished = false
        /// Claude's final text: the reply after its last tool call.
        var reply: String?
        /// Claude called a tool that has no result yet (running, or waiting for permission).
        var pendingToolUse = false
        var durationMs: Int?
        var lastActivity: Date?
    }

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Normalised start of a prompt, used to recognise it in the transcript.
    static func promptKey(for text: String) -> String {
        String(normalized(text).prefix(60))
    }

    // MARK: - Finding the transcript

    /// The live transcript for a session, following "continued-in" links to the
    /// file a session moved on to (Claude Code starts a new file when it continues).
    static func transcriptURL(sessionId: String, in projects: URL = projectsDirectory) -> URL? {
        var id = sessionId
        var found: URL?
        for _ in 0..<8 {
            guard let url = locate(id, in: projects) else { break }
            found = url
            guard let next = continuation(of: url), next != id else { break }
            id = next
        }
        return found
    }

    private static func locate(_ sessionId: String, in projects: URL) -> URL? {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return nil }
        return folders
            .map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The session a transcript continued in, if its tail says so.
    static func continuation(of url: URL) -> String? {
        for line in tail(of: url, maxBytes: 64 * 1024).lines.reversed() where line.contains("\"continued-in\"") {
            if let json = object(line), let next = json["continuedInSessionId"] as? String {
                return next
            }
        }
        return nil
    }

    /// The last lines of a file, without the partial first line of the window.
    /// `isCut` is true when the file is longer than the window.
    static func tail(of url: URL, maxBytes: UInt64) -> (lines: [String], isCut: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > maxBytes ? end - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return ([], false) }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return (lines, start > 0)
    }

    // MARK: - Reading the turn

    /// Reads the turn for a prompt sent at `sentAt`. Returns nil when the transcript can't be found.
    static func turn(promptKey: String, sentAt: Date, sessionId: String, in projects: URL = projectsDirectory) -> Turn? {
        guard let url = transcriptURL(sessionId: sessionId, in: projects) else { return nil }
        let continued = url.deletingPathExtension().lastPathComponent != sessionId
        let window = tail(of: url, maxBytes: 4 * 1024 * 1024)
        return turn(promptKey: promptKey, sentAt: sentAt, lines: window.lines,
                    startsTracking: continued, windowIsCut: window.isCut)
    }

    /// Parses transcript lines into the turn that started with our prompt.
    ///
    /// Normally the turn starts at our prompt. If the prompt isn't in these lines,
    /// it may sit in an earlier file (`startsTracking`, for a continued session)
    /// or have scrolled out of a tail window (`windowIsCut`, when every line is
    /// newer than `sentAt`); then the turn is tracked from the first line.
    /// A different prompt after the turn has started ends it.
    static func turn(promptKey: String, sentAt: Date, lines: [String],
                     startsTracking: Bool = false, windowIsCut: Bool = false) -> Turn {
        let cutoff = sentAt.addingTimeInterval(-2)

        // Parse once, skipping the bulky entry types and subagent (sidechain) entries.
        let entries: [(json: [String: Any], timestamp: Date)] = lines.compactMap { line in
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"")
                    || line.contains("\"type\":\"system\"") || line.contains("\"type\":\"queue-operation\""),
                  let json = object(line),
                  let timestamp = (json["timestamp"] as? String).flatMap(date),
                  json["isSidechain"] as? Bool != true
            else { return nil }
            return (json, timestamp)
        }

        let isOurPrompt = { (json: [String: Any]) -> Bool in
            guard json["type"] as? String == "user", json["isMeta"] as? Bool != true,
                  let text = promptText((json["message"] as? [String: Any])?["content"])
            else { return false }
            return matches(text, promptKey)
        }
        let promptInLines = entries.contains { $0.timestamp >= cutoff && isOurPrompt($0.json) }
        let windowStartsAfterSend = windowIsCut && (entries.first.map { $0.timestamp > cutoff } ?? false)

        var turn = Turn()
        var tracking = !promptInLines && (startsTracking || windowStartsAfterSend)
        if tracking { turn.promptSeen = true }
        var finalTexts: [String] = []

        scan: for (json, timestamp) in entries where timestamp >= cutoff {
            let message = json["message"] as? [String: Any] ?? [:]
            switch json["type"] as? String {
            case "queue-operation":
                if !tracking, let content = json["content"] as? String, matches(content, promptKey) {
                    turn.promptSeen = true
                }

            case "user":
                let content = message["content"]
                if let text = promptText(content), json["isMeta"] as? Bool != true {
                    if !tracking {
                        // Without an exact match, a "[Pasted text …]" placeholder is assumed to be ours.
                        if isOurPrompt(json) || (!promptInLines && text.hasPrefix("[Pasted text")) {
                            tracking = true
                            turn.promptSeen = true
                            turn.lastActivity = timestamp
                        }
                    } else {
                        // A later prompt: our turn is over.
                        break scan
                    }
                } else if tracking, hasToolResult(content) {
                    turn.pendingToolUse = false
                    turn.finished = false
                    finalTexts = []
                    turn.lastActivity = timestamp
                }

            case "assistant" where tracking:
                let blocks = message["content"] as? [[String: Any]] ?? []
                let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                finalTexts.append(contentsOf: texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                if blocks.contains(where: { $0["type"] as? String == "tool_use" }) {
                    turn.pendingToolUse = true
                    turn.finished = false
                }
                if message["stop_reason"] as? String == "end_turn" {
                    turn.finished = true
                    turn.pendingToolUse = false
                }
                turn.lastActivity = timestamp

            case "system" where tracking:
                if json["subtype"] as? String == "turn_duration" {
                    turn.durationMs = (json["durationMs"] as? NSNumber)?.intValue
                    turn.finished = true
                    turn.pendingToolUse = false
                }

            default:
                break
            }
        }

        if !finalTexts.isEmpty { turn.reply = finalTexts.joined(separator: "\n\n") }
        return turn
    }

    // MARK: - Helpers

    private static func object(_ line: String) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func date(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    /// A user entry's typed text; nil for tool results.
    private static func promptText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]],
              !blocks.contains(where: { $0["type"] as? String == "tool_result" })
        else { return nil }
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func hasToolResult(_ content: Any?) -> Bool {
        (content as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false
    }

    private static func matches(_ text: String, _ key: String) -> Bool {
        !key.isEmpty && normalized(text).hasPrefix(key)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
