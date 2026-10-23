//
//  PromptTemplate.swift
//  PromptSchedule
//

import Foundation
import SwiftData

/// A reusable prompt (Premium). `{{name}}` placeholders are filled in when the
/// template is used; see `TemplateEngine` for the built-in variables.
@Model
final class PromptTemplate {
    var name: String
    var body: String
    var createdAt: Date

    init(name: String, body: String) {
        self.name = name
        self.body = body
        self.createdAt = Date()
    }

    static let starters: [(String, String)] = [
        ("Fix build errors", "Build the project in {{folder}}, fix every compile error and warning at its root cause, and re-run the build until it is clean. Summarise what you changed."),
        ("Write tests", "Write unit tests for {{file}}. Cover the main paths and edge cases, follow the project's existing test conventions, and run them."),
        ("Review branch", "Review the changes on branch {{branch}} for bugs, missing error handling and unclear code. List findings by severity with file and line."),
        ("Daily standup", "Summarise what changed in {{folder}} since yesterday ({{date}}) and what's left to do."),
    ]
}
