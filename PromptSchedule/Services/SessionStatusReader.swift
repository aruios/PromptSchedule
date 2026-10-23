//
//  SessionStatusReader.swift
//  PromptSchedule
//

import Foundation

/// Reads `~/.claude/sessions/<pid>.json`, where Claude Code keeps each
/// session's live status ("idle" / "busy") and session ID.
/// Transcripts are read by `TranscriptReader`.
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
}
