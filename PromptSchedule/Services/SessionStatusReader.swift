//
//  SessionStatusReader.swift
//  PromptSchedule
//

import Foundation

/// Reads the files Claude Code keeps for each session:
/// - `~/.claude/sessions/<pid>.json` — live status ("idle" / "busy")
/// - `~/.claude/projects/<folder>/<sessionId>.jsonl` — the transcript
///
/// These are Claude Code internals, so every field is optional and failures
/// simply mean "unknown".
nonisolated enum SessionStatusReader {
    struct Info {
        var status: SessionStatus
        var statusUpdatedAt: Date?
        var sessionId: String?
        var cwd: String?
    }

    private struct StatusFile: Decodable {
        var status: String?
        var statusUpdatedAt: Double?
        var sessionId: String?
        var cwd: String?
    }

    private static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func read(pid: Int32) -> Info? {
        let url = claudeDirectory.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(StatusFile.self, from: data)
        else { return nil }
        return Info(
            status: file.status.flatMap(SessionStatus.init(rawValue:)) ?? .unknown,
            statusUpdatedAt: file.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            sessionId: file.sessionId,
            cwd: file.cwd
        )
    }

    /// The text of Claude's most recent reply in the session, if it can be found.
    static func lastReply(sessionId: String) -> String? {
        let projects = claudeDirectory.appendingPathComponent("projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ) else { return nil }
        guard let transcript = folders
            .map({ $0.appendingPathComponent("\(sessionId).jsonl") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let handle = try? FileHandle(forReadingFrom: transcript)
        else { return nil }
        defer { try? handle.close() }

        // Only the tail matters; transcripts can be large.
        let window: UInt64 = 512 * 1024
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > window ? end - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}
