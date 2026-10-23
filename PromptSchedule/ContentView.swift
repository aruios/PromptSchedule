//
//  ContentView.swift
//  PromptSchedule
//
//  Created by Arun Madasamy on 10/23/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PromptItem.createdAt) private var items: [PromptItem]

    @State private var dispatcher = Dispatcher()
    @State private var selectedSessions: Set<Int32> = []
    @State private var draft = ""
    @State private var draftOriginal: String?
    @State private var tableSelection: Set<PersistentIdentifier> = []
    @State private var sheet: SheetRequest?

    private enum SheetRequest: Identifiable {
        case composer
        case edit(PromptItem)

        var id: String {
            switch self {
            case .composer: "composer"
            case .edit(let item): "edit-\(item.persistentModelID.hashValue)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !dispatcher.hasAccessibility { accessibilityBanner }
            header
            composer
            Divider()
            queueTable
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar { toolbar }
        .sheet(item: $sheet) { request in
            switch request {
            case .composer:
                ReframeSheet(original: draftOriginal ?? draft, startReframing: true) { text in
                    if draftOriginal == nil { draftOriginal = draft }
                    draft = text
                }
            case .edit(let item):
                ReframeSheet(original: item.originalText ?? item.text, current: item.text, startReframing: false) { text in
                    if item.originalText == nil { item.originalText = item.text }
                    item.text = text
                    // An edited prompt goes back into the queue.
                    item.targets = item.targets.map { var t = $0; t.state = .queued; t.error = nil; return t }
                    item.sentAt = nil
                }
            }
        }
        .task {
            // Keep the session list fresh while the window is open.
            while !Task.isCancelled {
                await dispatcher.refreshSessions()
                let alive = Set(dispatcher.sessions.map(\.id))
                selectedSessions.formIntersection(alive)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Sections

    private var accessibilityBanner: some View {
        HStack {
            Image(systemName: "hand.raised.fill")
            Text("PromptSchedule needs Accessibility access to paste prompts into Terminal.")
            Spacer()
            Button("Grant Access") { dispatcher.requestAccessibility() }
        }
        .padding(10)
        .background(.yellow.opacity(0.25))
    }

    private var header: some View {
        HStack {
            Text("Send to:").foregroundStyle(.secondary)
            SessionPicker(sessions: dispatcher.sessions, selection: $selectedSessions)
            Button {
                Task { await dispatcher.refreshSessions() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh running sessions")
            Spacer()
            Text("\(dispatcher.sessions.count) Claude session\(dispatcher.sessions.count == 1 ? "" : "s") running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding([.horizontal, .top])
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if draft.isEmpty {
                    Text("Type a prompt…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                if draftOriginal != nil {
                    Label("Reframed", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    Button("Undo") {
                        draft = draftOriginal ?? draft
                        draftOriginal = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer()
                Button {
                    sheet = .composer
                } label: {
                    Label("Reframe", systemImage: "sparkles")
                }
                .disabled(trimmedDraft.isEmpty)

                Button("Add to Queue") { addDraft(sendNow: false) }
                    .disabled(!canQueue)
                    .keyboardShortcut(.return, modifiers: [.command])

                Button {
                    addDraft(sendNow: true)
                } label: {
                    Label("Send Now", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canQueue)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        }
        .padding()
    }

    private var queueTable: some View {
        Table(items, selection: $tableSelection) {
            TableColumn("#") { item in
                Text("\((items.firstIndex(of: item) ?? 0) + 1)")
                    .foregroundStyle(.secondary)
            }
            .width(28)

            TableColumn("Prompt") { item in
                HStack(alignment: .top, spacing: 4) {
                    if item.isReframed {
                        Image(systemName: "sparkles").foregroundStyle(.purple).help("Reframed")
                    }
                    Text(item.text).lineLimit(2).help(item.text)
                }
            }

            TableColumn("Sessions") { item in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.targets, id: \.self) { target in
                        HStack(spacing: 4) {
                            StateIcon(state: target.state)
                            Text(target.name).lineLimit(1)
                        }
                        .help(target.error ?? target.state.rawValue.capitalized)
                    }
                }
                .font(.callout)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Status") { item in
                HStack(spacing: 4) {
                    StateIcon(state: dispatcher.isPending(item) && item.state == .queued ? .sending : item.state)
                    Text(statusText(for: item))
                }
            }
            .width(90)

            TableColumn("") { item in
                HStack(spacing: 6) {
                    Button { dispatcher.send([item]) } label: {
                        Image(systemName: item.state == .failed ? "arrow.clockwise" : "paperplane")
                    }
                    .help(item.state == .failed ? "Retry failed sessions" : "Send")
                    .disabled(dispatcher.isPending(item))

                    Button { sheet = .edit(item) } label: { Image(systemName: "pencil") }
                        .help("Edit / Reframe")
                        .disabled(dispatcher.isPending(item))

                    Button { delete([item]) } label: { Image(systemName: "trash") }
                        .help("Delete")
                        .disabled(dispatcher.isPending(item))
                }
                .buttonStyle(.borderless)
            }
            .width(80)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            let chosen = items.filter { ids.contains($0.persistentModelID) }
            Button("Send") { dispatcher.send(chosen) }
            if chosen.count == 1, let item = chosen.first {
                Button("Edit / Reframe…") { sheet = .edit(item) }
            }
            Button("Retarget to Selected Sessions") { retarget(chosen) }
                .disabled(selectedSessions.isEmpty)
            Divider()
            Button("Delete", role: .destructive) { delete(chosen) }
        } primaryAction: { ids in
            if let item = items.first(where: { ids.contains($0.persistentModelID) }) {
                sheet = .edit(item)
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "Queue is empty",
                    systemImage: "tray",
                    description: Text("Pick sessions, type a prompt and press Add to Queue.")
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if dispatcher.isSending {
                ProgressView().controlSize(.small)
            }
            Button {
                dispatcher.send(items.filter { $0.state == .queued })
            } label: {
                Label("Send All Queued (\(queuedCount))", systemImage: "paperplane.circle.fill")
            }
            .disabled(queuedCount == 0)
            .help("Send every queued prompt, in order")

            Button {
                delete(items.filter { $0.state == .sent })
            } label: {
                Label("Clear Sent", systemImage: "checkmark.circle.badge.xmark")
            }
            .disabled(!items.contains { $0.state == .sent })
            .help("Remove prompts that were delivered")
        }
    }

    // MARK: - Actions

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canQueue: Bool {
        !trimmedDraft.isEmpty && !selectedSessions.isEmpty
    }

    private var queuedCount: Int {
        items.filter { $0.state == .queued && !dispatcher.isPending($0) }.count
    }

    private var selectedTargets: [PromptTarget] {
        dispatcher.sessions.filter { selectedSessions.contains($0.id) }.map(PromptTarget.init)
    }

    private func addDraft(sendNow: Bool) {
        let original = draftOriginal.flatMap { $0 == draft ? nil : $0 }
        let item = PromptItem(text: trimmedDraft, originalText: original, targets: selectedTargets)
        modelContext.insert(item)
        draft = ""
        draftOriginal = nil
        if sendNow { dispatcher.send([item]) }
    }

    private func retarget(_ chosen: [PromptItem]) {
        for item in chosen where !dispatcher.isPending(item) {
            item.targets = selectedTargets
            item.sentAt = nil
        }
    }

    private func delete(_ chosen: [PromptItem]) {
        for item in chosen where !dispatcher.isPending(item) {
            modelContext.delete(item)
        }
    }

    private func statusText(for item: PromptItem) -> String {
        if dispatcher.isPending(item) && item.state == .queued { return "Waiting" }
        switch item.state {
        case .queued: return "Queued"
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .failed:
            let failed = item.targets.filter { $0.state == .failed }.count
            return "Failed \(failed)/\(item.targets.count)"
        }
    }
}

private struct StateIcon: View {
    let state: DeliveryState

    var body: some View {
        switch state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .sending: ProgressView().controlSize(.mini)
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: PromptItem.self, inMemory: true)
}
