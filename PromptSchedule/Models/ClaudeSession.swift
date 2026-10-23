//
//  ClaudeSession.swift
//  PromptSchedule
//

import Foundation

/// An interactive Claude Code process running in a terminal tab.
nonisolated struct ClaudeSession: Identifiable, Hashable, Sendable {
    var pid: Int32
    /// Full device path, e.g. "/dev/ttys006" — matches Terminal's `tty of tab`.
    var tty: String
    var cwd: String?

    var id: Int32 { pid }

    var folderName: String {
        guard let cwd else { return "unknown folder" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var shortTTY: String {
        tty.replacingOccurrences(of: "/dev/", with: "")
    }

    var name: String {
        "\(folderName) · \(shortTTY)"
    }
}
