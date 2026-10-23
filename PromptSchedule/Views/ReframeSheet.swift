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
    @AppStorage(Premium.key) private var isPremium = false
    @AppStorage(Premium.reframeStyleKey) private var styleRaw = ReframeStyle.standard.rawValue
    @AppStorage(Premium.customReframeKey) private var customInstructions = ""
    @State private var revised: String
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(original: String, current: String? = nil, startReframing: Bool, onUse: @escaping (String) -> Void) {
        self.original = original
        self.startReframing = startReframing
        self.onUse = onUse
        _revised = State(initialValue: current ?? original)
    }

    /// Premium styles fall back to Standard when Premium is off.
    private var style: ReframeStyle {
        let chosen = ReframeStyle(rawValue: styleRaw) ?? .standard
        return chosen.isPremium && !isPremium ? .standard : chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reframe Prompt").font(.title2.bold())
                Spacer()
                stylePicker
            }

            if style == .custom {
                TextField("Custom instructions, e.g. “Write it as a user story with acceptance criteria”",
                          text: $customInstructions, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }

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

    private var stylePicker: some View {
        Menu {
            ForEach(ReframeStyle.allCases) { option in
                Button {
                    styleRaw = option.rawValue
                } label: {
                    if option == style {
                        Label(option.label, systemImage: "checkmark")
                    } else if option.isPremium && !isPremium {
                        Label(option.label, systemImage: "crown.fill")
                    } else {
                        Text(option.label)
                    }
                }
                .disabled(option.isPremium && !isPremium)
            }
        } label: {
            Label("Style: \(style.label)", systemImage: "wand.and.stars")
        }
        .fixedSize()
        .disabled(isWorking)
        .help(isPremium ? "How the prompt is rewritten" : "More styles with Premium")
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
            revised = try await PromptReframer.reframe(original, style: style, custom: customInstructions)
        } catch {
            errorMessage = "Reframe failed: \(error.localizedDescription)"
        }
    }
}
