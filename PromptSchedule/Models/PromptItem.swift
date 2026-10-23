//
//  PromptItem.swift
//  PromptSchedule
//

import Foundation
import SwiftData

/// Delivery state of a prompt for one target session.
nonisolated enum DeliveryState: String, Codable, Sendable {
    case queued, sending, sent, failed
}

/// One Claude session a prompt should be delivered to, with its own delivery state.
nonisolated struct PromptTarget: Codable, Hashable, Sendable {
    var pid: Int32
    var tty: String
    var name: String
    var state: DeliveryState = .queued
    var error: String?

    init(session: ClaudeSession) {
        pid = session.pid
        tty = session.tty
        name = session.name
    }
}

@Model
final class PromptItem {
    var createdAt: Date
    var text: String
    /// The text as first typed, kept when the prompt has been reframed.
    var originalText: String?
    var targets: [PromptTarget]
    var sentAt: Date?

    init(text: String, originalText: String? = nil, targets: [PromptTarget]) {
        self.createdAt = Date()
        self.text = text
        self.originalText = originalText
        self.targets = targets
    }

    /// Overall state summarised across all targets.
    var state: DeliveryState {
        let states = targets.map(\.state)
        if states.contains(.sending) { return .sending }
        if states.contains(.failed) { return .failed }
        if !states.isEmpty && states.allSatisfy({ $0 == .sent }) { return .sent }
        return .queued
    }

    var isReframed: Bool {
        originalText != nil && originalText != text
    }
}
