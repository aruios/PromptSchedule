//
//  NewSessionSheet.swift
//  PromptSchedule
//

import AppKit
import SwiftUI

/// Picks a folder and terminal, then starts a new Claude Code session there.
struct NewSessionSheet: View {
    /// Folders of the sessions currently running, offered as quick choices.
    let runningFolders: [String]
    /// Called with the folder once the terminal has been opened.
    let onLaunched: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(Premium.key) private var isPremium = false
    @AppStorage("recentSessionFolders") private var recentFoldersRaw = ""
    @State private var folder = ""
    @State private var terminal: TerminalKind = .terminal
    @State private var firstPrompt = ""
    @State private var isLaunching = false
    @State private var errorMessage: String?

    private var recentFolders: [String] {
        recentFoldersRaw.split(separator: "\n").map(String.init)
    }

    /// Recent folders first, then running sessions' folders, without duplicates.
    private var suggestions: [String] {
        var seen = Set<String>()
        return (recentFolders + runningFolders).filter { seen.insert($0).inserted }
    }

    private var availableTerminals: [TerminalKind] {
        var kinds: [TerminalKind] = [.terminal]
        if SessionLauncher.isITermInstalled { kinds.append(.iTerm) }
        if SessionLauncher.isTmuxInstalled { kinds.append(.tmux) }
        return kinds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Claude Session").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Project folder").font(.headline)
                HStack {
                    TextField("/path/to/project", text: $folder)
                        .textFieldStyle(.roundedBorder)
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { path in
                                Button(path) { folder = path }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .fixedSize()
                        .help("Recent folders")
                    }
                    Button("Choose…", action: chooseFolder)
                }
                if !folder.isEmpty && !isFolder(folder) {
                    Text("This folder doesn't exist.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if availableTerminals.count > 1 {
                Picker("Open in", selection: $terminal) {
                    ForEach(availableTerminals, id: \.self) { kind in
                        Text(kind.isPremium && !isPremium ? "\(kind.label) (Premium)" : kind.label)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("First prompt (optional)").font(.headline)
                TextField("Claude starts working on this straight away", text: $firstPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await launch() }
                } label: {
                    if isLaunching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Start Session", systemImage: "play.fill")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canLaunch)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if folder.isEmpty { folder = suggestions.first ?? "" }
        }
    }

    private var canLaunch: Bool {
        !isLaunching && isFolder(folder) && (isPremium || !terminal.isPremium)
    }

    private func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded(path), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func expanded(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if isFolder(folder) { panel.directoryURL = URL(fileURLWithPath: expanded(folder)) }
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }

    private func launch() async {
        isLaunching = true
        errorMessage = nil
        defer { isLaunching = false }

        let path = expanded(folder)
        let prompt = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await SessionLauncher.launch(in: path, terminal: terminal, firstPrompt: prompt.isEmpty ? nil : prompt)
            remember(path)
            onLaunched(path)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remember(_ path: String) {
        let updated = [path] + recentFolders.filter { $0 != path }
        recentFoldersRaw = updated.prefix(8).joined(separator: "\n")
    }
}
