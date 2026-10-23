//
//  Dispatcher.swift
//  PromptSchedule
//

import Foundation
import Observation
import SwiftData

/// Tracks running sessions and delivers queued prompts.
///
/// A loop ticks every two seconds: it refreshes the session list, then sends
/// every prompt that is ready. Delivery is strictly serial because each send
/// drives the keyboard and clipboard.
///
/// A prompt is ready when the user pressed Send, or (Premium) when its
/// schedule is due or Autopilot is on. With Premium, a session only receives
/// its next prompt once Claude has gone idle again, so prompts to the same
/// session run one after another instead of piling up.
@Observable
final class Dispatcher {
    private(set) var sessions: [ClaudeSession] = []
    private(set) var isSending = false
    private(set) var hasAccessibility = SessionSender.hasAccessibility()
    /// False until the first scan finishes, so an empty list isn't mistaken for "no sessions".
    private(set) var hasScanned = false

    /// Sessions we delivered to and are waiting on to finish (Premium).
    private(set) var awaiting: [Int32: Awaiting] = [:]

    struct Awaiting {
        var since: Date
        var sessionName: String
        var prompt: String
    }

    private let context: ModelContext
    private var isTicking = false

    init(container: ModelContainer) {
        context = container.mainContext
        Task { await run() }
    }

    private func run() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refreshSessions() async {
        sessions = await SessionScanner.scan()
        hasScanned = true
        hasAccessibility = SessionSender.hasAccessibility()
    }

    func requestAccessibility() {
        hasAccessibility = SessionSender.hasAccessibility(prompt: true)
    }

    func session(for pid: Int32) -> ClaudeSession? {
        sessions.first { $0.pid == pid }
    }

    /// Asks for the items to be delivered now. Delivered items are sent again;
    /// failed targets are retried.
    func send(_ items: [PromptItem]) {
        for item in items {
            if item.state == .sent {
                item.resetTargets()
            } else {
                item.targets = item.targets.map { var t = $0; if t.state == .failed { t.state = .queued; t.error = nil }; return t }
            }
            item.isArmed = true
        }
        Task { await tick() }
    }

    /// True while an item has been released for sending but is waiting its turn.
    func isWaiting(_ item: PromptItem) -> Bool {
        item.hasQueuedTargets && isReleased(item, now: Date())
    }

    // MARK: - Loop

    private func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        HotKey.shared.setEnabled(Premium.isOn)
        await refreshSessions()
        settleAwaiting()

        while let (item, pid) = nextDelivery() {
            await deliver(item, to: pid)
            await refreshSessions()
        }
    }

    private func isReleased(_ item: PromptItem, now: Date) -> Bool {
        if item.isArmed { return true }
        guard Premium.isOn else { return false }
        if let scheduledAt = item.scheduledAt { return scheduledAt <= now }
        return Premium.isAutopilotOn
    }

    /// The next (item, session) pair to send, keeping per-session order.
    private func nextDelivery() -> (PromptItem, Int32)? {
        let now = Date()
        let premium = Premium.isOn
        let descriptor = FetchDescriptor<PromptItem>(sortBy: [SortDescriptor(\.createdAt)])
        guard let items = try? context.fetch(descriptor) else { return nil }

        var blocked = Set<Int32>()
        for item in items where item.hasQueuedTargets && isReleased(item, now: now) {
            for target in item.targets where target.state == .queued && !blocked.contains(target.pid) {
                if premium, awaiting[target.pid] != nil || session(for: target.pid)?.status == .busy {
                    // Busy: hold this and every later prompt for the session.
                    blocked.insert(target.pid)
                    continue
                }
                return (item, target.pid)
            }
        }
        return nil
    }

    private func deliver(_ item: PromptItem, to pid: Int32) async {
        guard let index = item.targets.firstIndex(where: { $0.pid == pid }) else { return }
        isSending = true
        defer { isSending = false }

        let premium = Premium.isOn
        let target = item.targets[index]
        let session = session(for: pid)
        let terminal = session?.terminal ?? .terminal
        item.targets[index].state = .sending
        item.targets[index].error = nil

        var failure: String?
        if terminal.isPremium && !premium {
            failure = "\(terminal.label) sessions need Premium."
        } else {
            do {
                let text = premium ? await TemplateEngine.resolveBuiltIns(in: item.text, for: session) : item.text
                try await SessionSender.send(text, to: target, via: terminal)
                if premium {
                    awaiting[pid] = Awaiting(since: Date(), sessionName: target.name, prompt: item.text)
                }
            } catch {
                failure = error.localizedDescription
            }
        }

        // The item may have been deleted or retargeted while we were sending.
        guard !item.isDeleted, let current = item.targets.firstIndex(where: { $0.pid == pid }) else { return }
        item.targets[current].state = failure == nil ? .sent : .failed
        item.targets[current].error = failure
        finishIfDone(item)
    }

    private func finishIfDone(_ item: PromptItem) {
        guard !item.hasQueuedTargets, !item.targets.contains(where: { $0.state == .sending }) else { return }
        item.isArmed = false
        if item.state == .sent { item.sentAt = Date() }
        if let scheduledAt = item.scheduledAt, let next = item.repeatRule.next(after: scheduledAt) {
            item.scheduledAt = next
            item.resetTargets()
        }
    }

    /// Clears sessions that have finished our prompt, notifying with Claude's reply.
    private func settleAwaiting() {
        let now = Date()
        for (pid, waiting) in awaiting {
            guard let session = session(for: pid) else {
                awaiting[pid] = nil
                continue
            }
            let finished = session.status == .idle && (session.statusUpdatedAt ?? .distantPast) > waiting.since
            // No status file, or the prompt never made Claude busy: stop waiting.
            let untrackable = session.status == .unknown && now.timeIntervalSince(waiting.since) > 5
            let stale = session.status == .idle && now.timeIntervalSince(waiting.since) > 60
            guard finished || untrackable || stale else { continue }

            awaiting[pid] = nil
            if finished && Premium.isOn {
                let reply = session.sessionId.flatMap(SessionStatusReader.lastReply(sessionId:))
                Notifier.post(
                    title: "Claude finished · \(session.folderName)",
                    body: String((reply ?? waiting.prompt).prefix(240))
                )
            }
        }
    }
}
