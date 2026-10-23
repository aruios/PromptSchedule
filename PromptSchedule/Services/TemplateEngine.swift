//
//  TemplateEngine.swift
//  PromptSchedule
//

import Foundation

/// Handles `{{name}}` placeholders in prompts.
///
/// Built-in variables are filled automatically, per target session, at send time:
/// `{{folder}}`, `{{cwd}}`, `{{branch}}`, `{{date}}`, `{{time}}`.
/// Any other placeholder is asked for when a template is inserted.
nonisolated enum TemplateEngine {
    static let builtIns: Set<String> = ["folder", "cwd", "branch", "date", "time"]

    private static let pattern = /\{\{\s*([A-Za-z0-9_]+)\s*\}\}/

    /// Placeholder names in order of first appearance.
    static func placeholders(in text: String) -> [String] {
        var seen: [String] = []
        for match in text.matches(of: pattern) {
            let name = String(match.output.1)
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    /// Placeholders the user has to fill in themselves.
    static func userVariables(in text: String) -> [String] {
        placeholders(in: text).filter { !builtIns.contains($0.lowercased()) }
    }

    static func fill(_ text: String, with values: [String: String]) -> String {
        text.replacing(pattern) { match in
            let name = String(match.output.1)
            return values[name] ?? values[name.lowercased()] ?? String(match.output.0)
        }
    }

    /// Fills the built-in variables for one session.
    static func resolveBuiltIns(in text: String, for session: ClaudeSession?) async -> String {
        let used = Set(placeholders(in: text).map { $0.lowercased() })
        guard !used.isDisjoint(with: builtIns) else { return text }

        var values: [String: String] = [
            "date": Date().formatted(date: .abbreviated, time: .omitted),
            "time": Date().formatted(date: .omitted, time: .shortened),
        ]
        if let session {
            values["folder"] = session.folderName
            values["cwd"] = session.cwd
            if used.contains("branch"), let cwd = session.cwd,
               let result = try? await Shell.run("/usr/bin/git", ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]),
               result.status == 0 {
                values["branch"] = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fill(text, with: values)
    }
}
