//
//  ReframeSheet.swift
//  PromptSchedule
//

import SwiftUI

/// Shows the original prompt next to an editable, Claude-reframed version.
struct ReframeSheet: View {
    let original: String
    let startReframing: Bool
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var revised: String
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(original: String, current: String? = nil, startReframing: Bool, onUse: @escaping (String) -> Void) {
        self.original = original
        self.startReframing = startReframing
        self.onUse = onUse
        _revised = State(initialValue: current ?? original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reframe Prompt").font(.title2.bold())

            HStack(alignment: .top, spacing: 12) {
                column("Original") {
                    ScrollView {
                        Text(original)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                column("Reframed (editable)") {
                    ZStack {
                        TextEditor(text: $revised)
                            .font(.body)
                            .disabled(isWorking)
                            .opacity(isWorking ? 0.4 : 1)
                        if isWorking { ProgressView("Reframing with Claude…") }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            }
            .frame(minHeight: 260)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Button {
                    Task { await reframe() }
                } label: {
                    Label("Reframe Again", systemImage: "sparkles")
                }
                .disabled(isWorking)

                Button("Keep Original") {
                    onUse(original)
                    dismiss()
                }
                .disabled(isWorking)

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use This") {
                    onUse(revised.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 400)
        .task {
            if startReframing { await reframe() }
        }
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reframe() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            revised = try await PromptReframer.reframe(original)
        } catch {
            errorMessage = "Reframe failed: \(error.localizedDescription)"
        }
    }
}
