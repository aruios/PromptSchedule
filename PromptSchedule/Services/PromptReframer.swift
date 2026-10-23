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
        try await ClaudeCLI.print(instructions(style: style, custom: custom) + "\n" + prompt, model: "sonnet")
    }
}
