//
//  PromptReframer.swift
//  PromptSchedule
//

import Foundation

/// How a prompt should be rewritten. `.standard` is free; the rest are Premium.
nonisolated enum ReframeStyle: String, CaseIterable, Identifiable, Sendable {
    case standard, concise, plan, bugReport, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .concise: "Concise"
        case .plan: "Step-by-step plan"
        case .bugReport: "Bug report"
        case .custom: "Custom…"
        }
    }

    var isPremium: Bool { self != .standard }

    fileprivate var guidance: String {
        switch self {
        case .standard:
            "Make the goal and expected result explicit, and structure it with short steps or bullet points if that helps."
        case .concise:
            "Make it as short as possible while staying unambiguous: one or two sentences, no lists unless essential."
        case .plan:
            "Turn it into a numbered step-by-step plan for the assistant to follow, ending with how to verify the work is done."
        case .bugReport:
            "Structure it as a bug report with these headings: Problem, Steps to reproduce, Expected, Actual, What to fix. Leave a heading out if the prompt gives nothing for it."
        case .custom:
            ""
        }
    }
}

/// Rewrites a prompt into a clearer, better-structured one using the local
/// `claude` CLI in headless mode, so it reuses the user's existing login.
nonisolated enum PromptReframer {
    private static func instructions(style: ReframeStyle, custom: String) -> String {
        let guidance = style == .custom && !custom.isEmpty ? custom : style.guidance
        return """
        You are a prompt editor. Rewrite the prompt below so an AI coding assistant \
        (Claude Code) understands it clearly: fix grammar and spelling. \(guidance) \
        Keep the original intent, language and every technical detail \
        (file paths, names, code, error messages, and any {{placeholders}}). \
        Do not answer or carry out the prompt. \
        Output only the rewritten prompt, with no preamble, explanation or quotes.

        Prompt:
        """
    }

    static func reframe(_ prompt: String, style: ReframeStyle = .standard, custom: String = "") async throws -> String {
        guard let claude = await locateClaude() else {
            throw ShellError.failed("Couldn't find the claude CLI. Install Claude Code or add it to your PATH.")
        }

        // GUI apps get a minimal PATH, so add the CLI's own folder and the usual tool locations.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = [URL(fileURLWithPath: claude).deletingLastPathComponent().path,
                          "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (extraPaths + [environment["PATH"] ?? ""]).joined(separator: ":")

        let result = try await Shell.run(
            claude,
            ["-p", "--model", "sonnet", instructions(style: style, custom: custom) + "\n" + prompt],
            in: FileManager.default.temporaryDirectory,
            environment: environment,
            timeout: 180
        )
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !output.isEmpty else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.failed(detail.isEmpty ? "claude exited with status \(result.status)" : detail)
        }
        return output
    }

    /// Finds the claude executable: common install locations first, then an
    /// interactive login shell so PATH entries from ~/.zshrc are honoured too.
    private static func locateClaude() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        guard let result = try? await Shell.run("/bin/zsh", ["-ilc", "command -v claude"]) else { return nil }
        let path = result.output
            .split(separator: "\n")
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
