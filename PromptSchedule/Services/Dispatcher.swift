//
//  Dispatcher.swift
//  PromptSchedule
//

import Foundation
import Observation

/// Tracks running sessions and delivers queued prompts one at a time.
/// Sending is strictly serial because each delivery drives the keyboard and clipboard.
@Observable
final class Dispatcher {
    private(set) var sessions: [ClaudeSession] = []
    private(set) var isSending = false
    private(set) var hasAccessibility = TerminalSender.hasAccessibility()

    private var pending: [PromptItem] = []

    func refreshSessions() async {
        sessions = await SessionScanner.scan()
        hasAccessibility = TerminalSender.hasAccessibility()
    }

    func requestAccessibility() {
        hasAccessibility = TerminalSender.hasAccessibility(prompt: true)
    }

    /// Adds items to the send queue and starts delivering if idle.
    func send(_ items: [PromptItem]) {
        for item in items where !pending.contains(where: { $0 === item }) {
            if item.state == .sent {
                // Re-sending a delivered prompt delivers it to every target again.
                item.targets = item.targets.map { var t = $0; t.state = .queued; t.error = nil; return t }
            }
            pending.append(item)
        }
        guard !isSending else { return }
        Task { await drain() }
    }

    func isPending(_ item: PromptItem) -> Bool {
        pending.contains { $0 === item }
    }

    private func drain() async {
        isSending = true
        defer { isSending = false }

        while !pending.isEmpty {
            let item = pending.removeFirst()
            for index in item.targets.indices where item.targets[index].state != .sent {
                item.targets[index].state = .sending
                item.targets[index].error = nil
                do {
                    try await TerminalSender.send(item.text, to: item.targets[index])
                    item.targets[index].state = .sent
                } catch {
                    item.targets[index].state = .failed
                    item.targets[index].error = error.localizedDescription
                }
            }
            if item.state == .sent { item.sentAt = Date() }
        }
    }
}
