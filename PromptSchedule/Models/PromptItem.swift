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

/// How a scheduled prompt repeats after it has been delivered.
nonisolated enum RepeatRule: String, CaseIterable, Identifiable, Sendable {
    case none, hourly, daily, weekdays, weekly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Once"
        case .hourly: "Every hour"
        case .daily: "Every day"
        case .weekdays: "Every weekday"
        case .weekly: "Every week"
        }
    }

    /// The first occurrence after `now`, stepping forward from `date`.
    func next(after date: Date, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        var candidate = date
        repeat {
            switch self {
            case .none: return nil
            case .hourly: candidate = calendar.date(byAdding: .hour, value: 1, to: candidate)!
            case .daily: candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
            case .weekly: candidate = calendar.date(byAdding: .day, value: 7, to: candidate)!
            case .weekdays:
                repeat {
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
                } while calendar.isDateInWeekend(candidate)
            }
        } while candidate <= now
        return candidate
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
    /// When a scheduled prompt should go out (Premium).
    var scheduledAt: Date?
    var repeatRaw: String = RepeatRule.none.rawValue
    /// Set when the user asks to send now; cleared once every target has been tried.
    var isArmed: Bool = false

    init(text: String, originalText: String? = nil, targets: [PromptTarget]) {
        self.createdAt = Date()
        self.text = text
        self.originalText = originalText
        self.targets = targets
    }

    var repeatRule: RepeatRule {
        get { RepeatRule(rawValue: repeatRaw) ?? .none }
        set { repeatRaw = newValue.rawValue }
    }

    /// Overall state summarised across all targets.
    var state: DeliveryState {
        let states = targets.map(\.state)
        if states.contains(.sending) { return .sending }
        if states.contains(.failed) { return .failed }
        if !states.isEmpty && states.allSatisfy({ $0 == .sent }) { return .sent }
        return .queued
    }

    var hasQueuedTargets: Bool {
        targets.contains { $0.state == .queued }
    }

    var isReframed: Bool {
        originalText != nil && originalText != text
    }

    func resetTargets() {
        targets = targets.map { var t = $0; t.state = .queued; t.error = nil; return t }
    }
}
