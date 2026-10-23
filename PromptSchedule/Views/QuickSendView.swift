//
//  QuickSendView.swift
//  PromptSchedule
//

import AppKit
import SwiftUI
import SwiftData

/// Compact composer used by the menu bar item and the ⌃⌥⌘P panel (Premium).
struct QuickSendView: View {
    @Environment(Dispatcher.self) private var dispatcher
    @Environment(\.modelContext) private var modelContext
    @AppStorage(Premium.key) private var isPremium = false
    @State private var selectedSessions: Set<Int32> = []
    @State private var draft = ""
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick Send").font(.headline)
                Spacer()
                SessionPicker(sessions: dispatcher.sessions, selection: $selectedSessions, isPremium: isPremium)
            }
            TextEditor(text: $draft)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("\(HotKey.displayString) opens this from anywhere")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Queue") { submit(sendNow: false) }
                    .disabled(!canSubmit)
                Button("Send") { submit(sendNow: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSubmit)
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedSessions.isEmpty
    }

    private func submit(sendNow: Bool) {
        let targets = dispatcher.sessions.filter { selectedSessions.contains($0.id) }.map(PromptTarget.init)
        let item = PromptItem(text: draft.trimmingCharacters(in: .whitespacesAndNewlines), targets: targets)
        modelContext.insert(item)
        if sendNow { dispatcher.send([item]) }
        draft = ""
        onDone()
    }
}

/// Floating panel hosting `QuickSendView`, toggled by the global shortcut.
final class QuickSendPanel {
    static let shared = QuickSendPanel()
    private var panel: NSPanel?

    private init() {}

    func configure(dispatcher: Dispatcher, container: ModelContainer) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: QuickSendView(onDone: { [weak panel] in panel?.orderOut(nil) })
                .environment(dispatcher)
                .modelContainer(container)
        )
        self.panel = panel
        HotKey.shared.action = { [weak self] in self?.toggle() }
    }

    func toggle() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.center()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
