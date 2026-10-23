//
//  NoteMaker.swift
//  PromptSchedule
//

import Foundation

/// Turns Claude's final reply into a short note for the queue (Premium).
nonisolated enum NoteMaker {
    static let maxLength = 160

    /// The reply's opening, as plain text, cut at a sentence end. Claude's replies
    /// usually lead with the outcome, so this is a good free summary.
    static func quickNote(from reply: String) -> String? {
        let withoutCode = reply.replacing(/```[\s\S]*?```/, with: "")

        var paragraphs: [String] = []
        var current: [String] = []
        for rawLine in withoutCode.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Tables, rules and headings don't make good notes.
            let skip = line.hasPrefix("|") || line.hasPrefix("---") || line.hasPrefix("#") || line.hasPrefix(">")
            if line.isEmpty || skip {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = []
                continue
            }
            current.append(plain(line))
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }

        let useful = paragraphs.filter { $0.contains(where: \.isLetter) }
        guard var note = useful.first else { return nil }
        // A very short opener ("Done.") reads better with what follows.
        if note.count < 40, useful.count > 1 { note += " " + useful[1] }
        return truncate(collapse(note))
    }

    /// A one-sentence summary written by Claude Haiku via `claude -p`.
    static func aiNote(from reply: String) async throws -> String {
        let prompt = """
        Summarise the outcome of this coding assistant's reply as one status note \
        of at most 25 words, e.g. "Fixed the login crash; all 42 tests pass." \
        Say what was done and whether it worked. Output only the note.

        Reply:
        \(reply.prefix(12_000))
        """
        let note = try await ClaudeCLI.print(prompt, model: "haiku", timeout: 90)
        return truncate(collapse(note.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n"))))
    }

    // MARK: - Helpers

    /// Strips list markers and inline markdown.
    private static func plain(_ line: String) -> String {
        var text = line
        text = text.replacing(/^([-*+]|\d+[.)])\s+/, with: "")
        text = text.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        return text
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cuts to `maxLength`, preferring a sentence end, else a word boundary with "…".
    static func truncate(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let window = String(text.prefix(maxLength))
        if let end = window.range(of: #"[.!?](?=\s)"#, options: [.regularExpression, .backwards]),
           window.distance(from: window.startIndex, to: end.upperBound) >= 60 {
            return String(window[..<end.upperBound])
        }
        let cut = window.prefix(maxLength - 1)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}
