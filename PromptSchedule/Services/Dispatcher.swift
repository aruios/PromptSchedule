//
//  Dispatcher.swift
//  PromptSchedule
//

import Foundation
import Observation
import SwiftData

/// Tracks running sessions, delivers queued prompts and (Premium) follows each
/// delivered prompt until Claude finishes, recording a short note on the result.
///
/// A loop ticks every two seconds: it refreshes the session list, checks the
/// prompts Claude is working on, then sends every prompt that is ready.
/// Delivery is strictly serial.
///
/// A prompt is ready when the user pressed Send, or (Premium) when its
/// schedule is due or Autopilot is on. With Premium, a session only receives
/// its next prompt once Claude has finished the previous one, so prompts to
/// the same session run one after another instead of piling up.
@Observable
final class Dispatcher {
    private(set) var sessions: [ClaudeSession] = []
    private(set) var isSending = false
    /// False until the first scan finishes, so an empty list isn't mistaken for "no sessions".
    private(set) var hasScanned = false
    /// Targets whose AI summary is being written, as "<item>|<pid>".
    private(set) var summarizing: Set<String> = []

    private let context: ModelContext
    private var isTicking = false
    /// Latest hook event per session ID (Premium, when the hooks are installed).
    private var stopEvents: [String: Date] = [:]
    private var permissionEvents: [String: Date] = [:]

    /// How long to wait for a delivered prompt to show up in the transcript.
    private static let promptArrivalTimeout: TimeInterval = 120

    init(container: ModelContainer, autoStart: Bool = true) {
        context = container.mainContext
        if autoStart { Task { await run() } }
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
        if Premium.isOn { trackResults() }

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

    private func allItems() -> [PromptItem] {
        let descriptor = FetchDescriptor<PromptItem>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The next (item, session) pair to send, keeping per-session order.
    private func nextDelivery() -> (PromptItem, Int32)? {
        let now = Date()
        let premium = Premium.isOn
        let items = allItems()

        // Sessions still working on a prompt we sent.
        var blocked = premium
            ? Set(items.flatMap { $0.targets.filter(\.isTracking).map(\.pid) })
            : []
        for item in items where item.hasQueuedTargets && isReleased(item, now: now) {
            for target in item.targets where target.state == .queued && !blocked.contains(target.pid) {
                if premium, session(for: target.pid)?.status == .busy {
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
        var sentText: String?
        if terminal.isPremium && !premium {
            failure = "\(terminal.label) sessions need Premium."
        } else {
            do {
                let text = premium ? await TemplateEngine.resolveBuiltIns(in: item.text, for: session) : item.text
                try await SessionSender.send(text, to: target, via: terminal)
                sentText = text
            } catch {
                failure = error.localizedDescription
            }
        }

        // The item may have been deleted or retargeted while we were sending.
        guard !item.isDeleted, let current = item.targets.firstIndex(where: { $0.pid == pid }) else { return }
        item.targets[current].state = failure == nil ? .sent : .failed
        item.targets[current].error = failure
        if let sentText, premium {
            startTracking(&item.targets[current], text: sentText, session: session)
        }
        finishIfDone(item)
    }

    private func finishIfDone(_ item: PromptItem) {
        guard !item.hasQueuedTargets, !item.targets.contains(where: { $0.state == .sending }) else { return }
        item.isArmed = false
        if item.state == .sent { item.sentAt = Date() }
        if let scheduledAt = item.scheduledAt, let next = item.repeatRule.next(after: scheduledAt) {
            item.scheduledAt = next
            item.requeueForNextRun()
        }
    }

    // MARK: - Results (Premium)

    private func startTracking(_ target: inout PromptTarget, text: String, session: ClaudeSession?) {
        target.clearResult()
        guard let sessionId = session?.sessionId else {
            target.note = "Results can't be tracked for this session (no Claude status file)."
            return
        }
        target.sessionId = sessionId
        target.promptKey = TranscriptReader.promptKey(for: text)
        target.sentAt = Date()
    }

    /// Checks every prompt Claude is working on and records how its turn ended.
    private func trackResults() {
        for event in ClaudeHooks.readNewEvents() {
            if event.name == "Stop" { stopEvents[event.sessionId] = event.receivedAt }
            if event.name == "Notification", event.message?.localizedCaseInsensitiveContains("permission") == true {
                permissionEvents[event.sessionId] = event.receivedAt
            }
        }

        let now = Date()
        for item in allItems() {
            for target in item.targets where target.isTracking {
                guard let sessionId = target.sessionId, let sentAt = target.sentAt,
                      let turn = TranscriptReader.turn(promptKey: target.promptKey ?? "", sentAt: sentAt, sessionId: sessionId)
                else {
                    if session(for: target.pid) == nil {
                        complete(item, pid: target.pid, outcome: .interrupted, reply: nil, durationMs: nil,
                                 note: "The session ended before Claude finished.")
                    }
                    continue
                }

                let liveId = TranscriptReader.transcriptURL(sessionId: sessionId)?
                    .deletingPathExtension().lastPathComponent ?? sessionId
                let stopped = (stopEvents[liveId] ?? .distantPast) > sentAt

                if turn.finished || (stopped && turn.promptSeen && !turn.pendingToolUse) {
                    let reply = turn.reply ?? ""
                    let outcome: TaskOutcome = reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                        ? .needsInput : .done
                    complete(item, pid: target.pid, outcome: outcome, reply: turn.reply, durationMs: turn.durationMs,
                             note: NoteMaker.quickNote(from: reply) ?? "Claude finished without a written reply.")
                } else if session(for: target.pid) == nil {
                    complete(item, pid: target.pid, outcome: .interrupted, reply: turn.reply, durationMs: nil,
                             note: "The session ended before Claude finished.")
                } else if !turn.promptSeen, now.timeIntervalSince(sentAt) > Self.promptArrivalTimeout,
                          session(for: target.pid)?.status != .busy {
                    complete(item, pid: target.pid, outcome: .interrupted, reply: nil, durationMs: nil,
                             note: "The prompt didn't show up in Claude's conversation.")
                } else if turn.pendingToolUse, isWaitingForPermission(target, liveId: liveId, turn: turn),
                          target.outcome != .waitingPermission {
                    markWaitingForPermission(item, pid: target.pid)
                }
            }
        }
    }

    /// Claude is stuck on a tool call: the permission hook fired, or the session's
    /// own status says it isn't busy (only trusted when it was updated after our send).
    private func isWaitingForPermission(_ target: PromptTarget, liveId: String, turn: TranscriptReader.Turn) -> Bool {
        let since = turn.lastActivity ?? target.sentAt ?? .distantPast
        if (permissionEvents[liveId] ?? .distantPast) > since { return true }
        guard let session = session(for: target.pid), let updated = session.statusUpdatedAt else { return false }
        return session.status == .idle && updated > since
    }

    private func markWaitingForPermission(_ item: PromptItem, pid: Int32) {
        guard let index = item.targets.firstIndex(where: { $0.pid == pid }) else { return }
        item.targets[index].outcome = .waitingPermission
        item.targets[index].note = "Claude is waiting for your permission to continue."
        notify(item, target: item.targets[index])
    }

    private func complete(_ item: PromptItem, pid: Int32, outcome: TaskOutcome, reply: String?,
                          durationMs: Int?, note: String) {
        guard let index = item.targets.firstIndex(where: { $0.pid == pid }) else { return }
        item.targets[index].outcome = outcome
        item.targets[index].completedAt = Date()
        item.targets[index].reply = reply
        item.targets[index].durationMs = durationMs
        item.targets[index].note = note
        item.targets[index].noteIsAI = false

        if Premium.isAISummariesOn, let reply, !reply.isEmpty {
            // The notification waits for the AI note, falling back to the quick note.
            Task { await summarize(item, pid: pid, reply: reply, notifyWhenDone: true) }
        } else {
            notify(item, target: item.targets[index])
        }
    }

    /// Replaces the quick note with an AI summary.
    func resummarize(_ item: PromptItem, pid: Int32) {
        guard let reply = item.targets.first(where: { $0.pid == pid })?.reply else { return }
        Task { await summarize(item, pid: pid, reply: reply, notifyWhenDone: false) }
    }

    func isSummarizing(_ item: PromptItem, pid: Int32) -> Bool {
        summarizing.contains(Self.key(item, pid))
    }

    private func summarize(_ item: PromptItem, pid: Int32, reply: String, notifyWhenDone: Bool) async {
        let key = Self.key(item, pid)
        summarizing.insert(key)
        defer { summarizing.remove(key) }

        let note = try? await NoteMaker.aiNote(from: reply)
        guard !item.isDeleted, let index = item.targets.firstIndex(where: { $0.pid == pid }) else { return }
        if let note, !note.isEmpty {
            item.targets[index].note = note
            item.targets[index].noteIsAI = true
        }
        if notifyWhenDone { notify(item, target: item.targets[index]) }
    }

    private static func key(_ item: PromptItem, _ pid: Int32) -> String {
        "\(item.persistentModelID.hashValue)|\(pid)"
    }

    private func notify(_ item: PromptItem, target: PromptTarget) {
        let folder = session(for: target.pid)?.folderName ?? target.name
        let title: String
        switch target.outcome {
        case .needsInput: title = "Claude needs your input · \(folder)"
        case .waitingPermission: title = "Claude is waiting for permission · \(folder)"
        case .interrupted: title = "Claude didn't finish · \(folder)"
        default: title = "Claude finished · \(folder)"
        }
        Notifier.post(title: title, body: target.note ?? "", item: item, pid: target.pid)
    }
}
