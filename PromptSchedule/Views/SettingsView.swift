//
//  SettingsView.swift
//  PromptSchedule
//

import SwiftUI

/// PromptSchedule › Settings… (⌘,)
struct SettingsView: View {
    @AppStorage(Premium.key) private var isPremium = false
    @AppStorage(Premium.aiSummariesKey) private var isAISummariesOn = false

    @State private var hooksInstalled = ClaudeHooks.isInstalled()
    @State private var confirmHooks = false
    @State private var hooksError: String?

    var body: some View {
        Form {
            if !isPremium {
                Label("Task results are a Premium feature. Turn on Premium in the main window to use them.",
                      systemImage: "crown")
                    .foregroundStyle(.secondary)
            }

            Section("Task results") {
                Toggle("Write notes with AI", isOn: $isAISummariesOn)
                Text("When Claude finishes, Claude Haiku writes a one-sentence note about the outcome using `claude -p`. This uses a little of your Claude usage. When off, the note is the opening of Claude's reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!isPremium)

            Section("Claude Code hooks") {
                LabeledContent("Status") {
                    Label(hooksInstalled ? "Installed" : "Not installed",
                          systemImage: hooksInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(hooksInstalled ? .green : .secondary)
                }
                Text("Optional. Adds Stop and Notification hooks to ~/.claude/settings.json so Claude Code tells PromptSchedule the moment a task finishes or needs permission. Without them, results are still found by reading Claude's transcripts. A backup is saved as settings.json.promptschedule-backup. Restart running Claude sessions for the hooks to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if hooksInstalled {
                        Button("Remove Hooks", role: .destructive) { update { try ClaudeHooks.uninstall() } }
                    } else {
                        Button("Install Hooks…") { confirmHooks = true }
                    }
                }
                if let hooksError {
                    Text(hooksError).font(.caption).foregroundStyle(.red)
                }
            }
            .disabled(!isPremium)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Change Claude Code settings?", isPresented: $confirmHooks) {
            Button("Install") { update { try ClaudeHooks.install() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PromptSchedule will add two hooks to ~/.claude/settings.json and keep the rest of the file as it is. A backup is saved first.")
        }
    }

    private func update(_ change: () throws -> Void) {
        do {
            try change()
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksInstalled = ClaudeHooks.isInstalled()
    }
}
