//
//  ClaudeSession.swift
//  PromptSchedule
//

import Foundation

/// The terminal app hosting a Claude session, which decides how prompts are delivered.
nonisolated enum TerminalKind: String, Sendable {
    case terminal, iTerm, tmux, unsupported

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm2"
        case .tmux: "tmux"
        case .unsupported: "Unsupported terminal"
        }
    }

    /// Terminal.app is free; the others are Premium.
    var isPremium: Bool { self == .iTerm || self == .tmux }
}

/// Whether Claude is working, as reported in ~/.claude/sessions/<pid>.json.
nonisolated enum SessionStatus: String, Sendable {
    case idle, busy, unknown
}

/// An interactive Claude Code process running in a terminal.
nonisolated struct ClaudeSession: Identifiable, Hashable, Sendable {
    var pid: Int32
    /// Full device path, e.g. "/dev/ttys006" — matches the terminal tab's tty.
    var tty: String
    var cwd: String?
    var terminal: TerminalKind = .unsupported
    var status: SessionStatus = .unknown
    var statusUpdatedAt: Date?
    var sessionId: String?

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
