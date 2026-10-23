//
//  ResultViews.swift
//  PromptSchedule
//

import AppKit
import SwiftUI

/// Icon for how Claude's turn ended; a spinner while it's still working.
struct OutcomeIcon: View {
    let target: PromptTarget

    var body: some View {
        switch target.outcome {
        case .done: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .needsInput: Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
        case .waitingPermission: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .interrupted: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case nil:
            if target.isTracking {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "minus").foregroundStyle(.tertiary)
            }
        }
    }
}

/// The queue table's Result cell: one short note per session.
struct ResultCell: View {
    let item: PromptItem
    let isPremium: Bool
    let onOpen: () -> Void

    var body: some View {
        if !isPremium {
            Label("Premium", systemImage: "crown")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if item.targets.allSatisfy({ $0.note == nil && !$0.isTracking }) {
            Text("—").foregroundStyle(.tertiary)
        } else {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(item.targets, id: \.pid) { target in
                        HStack(alignment: .top, spacing: 4) {
                            OutcomeIcon(target: target)
                            Text(target.note ?? (target.isTracking ? "Claude is working…" : "—"))
                                .lineLimit(2)
                                .foregroundStyle(target.note == nil ? .secondary : .primary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .help("Show Claude's full reply")
        }
    }
}

/// Side panel with the full result of a prompt, per session.
struct ResultPanel: View {
    let item: PromptItem
    @Environment(Dispatcher.self) private var dispatcher
    let onFollowUp: (Int32) -> Void

    @State private var revealError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt").font(.caption).foregroundStyle(.secondary)
                    Text(item.text)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }

                ForEach(item.targets, id: \.pid) { target in
                    TargetResult(item: item, target: target, onFollowUp: onFollowUp, onReveal: reveal)
                }

                if let revealError {
                    Label(revealError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reveal(_ target: PromptTarget) {
        let terminal = dispatcher.session(for: target.pid)?.terminal ?? .terminal
        Task {
            do {
                revealError = nil
                try await SessionSender.reveal(tty: target.tty, via: terminal)
            } catch {
                revealError = error.localizedDescription
            }
        }
    }
}

private struct TargetResult: View {
    let item: PromptItem
    let target: PromptTarget
    let onFollowUp: (Int32) -> Void
    let onReveal: (PromptTarget) -> Void
    @Environment(Dispatcher.self) private var dispatcher

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    OutcomeIcon(target: target)
                    Text(target.outcome?.label ?? (target.isTracking ? "Claude is working…" : "Not tracked"))
                        .font(.headline)
                    Spacer()
                    if let meta = metadata { Text(meta).font(.caption).foregroundStyle(.secondary) }
                }

                if let note = target.note {
                    HStack(alignment: .top, spacing: 4) {
                        if target.noteIsAI == true {
                            Image(systemName: "sparkles").foregroundStyle(.purple).help("Summary written by Claude Haiku")
                        }
                        Text(note).fontWeight(.medium).textSelection(.enabled)
                    }
                }

                if let reply = target.reply, !reply.isEmpty {
                    Divider()
                    Text(Self.markdown(reply))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(target.reply ?? target.note ?? "", forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(target.reply == nil && target.note == nil)

                    Button { onReveal(target) } label: { Label("Show in Terminal", systemImage: "terminal") }

                    Button { onFollowUp(target.pid) } label: { Label("Follow Up", systemImage: "arrowshape.turn.up.right") }
                        .disabled(dispatcher.session(for: target.pid) == nil)

                    Spacer()

                    if dispatcher.isSummarizing(item, pid: target.pid) {
                        ProgressView().controlSize(.small)
                    } else if target.reply != nil {
                        Button { dispatcher.resummarize(item, pid: target.pid) } label: {
                            Label("Summarize Again", systemImage: "sparkles")
                        }
                        .help("Write a one-sentence summary with Claude Haiku (uses a little of your Claude usage)")
                    }
                }
                .controlSize(.small)
                .labelStyle(.titleAndIcon)
            }
            .padding(4)
        } label: {
            Text(target.name).font(.subheadline.weight(.semibold))
        }
    }

    private var metadata: String? {
        var parts: [String] = []
        if let completedAt = target.completedAt {
            parts.append(completedAt.formatted(date: .omitted, time: .shortened))
        }
        if let ms = target.durationMs {
            parts.append("took " + Duration.milliseconds(ms).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Inline markdown (bold, code, links) with line breaks kept.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
