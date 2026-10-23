//
//  SessionPicker.swift
//  PromptSchedule
//

import SwiftUI

/// Dropdown-style button that opens a checkbox list of running Claude sessions.
struct SessionPicker: View {
    let sessions: [ClaudeSession]
    @Binding var selection: Set<Int32>
    var isPremium: Bool
    /// Latest result note per session (Premium).
    var notes: [Int32: String] = [:]
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text(title)
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if sessions.isEmpty {
                    Text("No Claude sessions running.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Select All") { selection = Set(sessions.filter(isSelectable).map(\.id)) }
                        Button("None") { selection.removeAll() }
                    }
                    .buttonStyle(.link)
                    Divider()
                    ForEach(sessions) { session in
                        row(for: session)
                    }
                }
            }
            .padding()
            .frame(minWidth: 300, maxWidth: 440, alignment: .leading)
        }
    }

    private func row(for session: ClaudeSession) -> some View {
        Toggle(isOn: binding(for: session.id)) {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(status: session.status)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(session.folderName)
                        if session.terminal.isPremium && !isPremium {
                            PremiumBadge()
                        }
                    }
                    Text(detail(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = notes[session.pid] {
                        Text(note)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(note)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!isSelectable(session))
        .help(helpText(for: session))
    }

    private func detail(for session: ClaudeSession) -> String {
        var parts = [session.terminal.label, session.shortTTY]
        if session.status != .unknown { parts.append(session.status.rawValue) }
        if let cwd = session.cwd { parts.append(cwd) }
        return parts.joined(separator: " · ")
    }

    private func helpText(for session: ClaudeSession) -> String {
        if session.terminal == .unsupported { return "PromptSchedule can't type into this terminal." }
        if session.terminal.isPremium && !isPremium { return "\(session.terminal.label) sessions need Premium." }
        return "pid \(session.pid)"
    }

    private func isSelectable(_ session: ClaudeSession) -> Bool {
        session.terminal != .unsupported && (isPremium || !session.terminal.isPremium)
    }

    private var title: String {
        let chosen = sessions.filter { selection.contains($0.id) }
        switch chosen.count {
        case 0: return sessions.isEmpty ? "No sessions" : "Select sessions"
        case 1: return chosen[0].name
        default: return "\(chosen.count) sessions selected"
        }
    }

    private func binding(for id: Int32) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}

/// Green when Claude is idle, orange while it's working.
struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(status == .unknown ? "Status unknown" : "Claude is \(status.rawValue)")
    }

    private var color: Color {
        switch status {
        case .idle: .green
        case .busy: .orange
        case .unknown: .gray.opacity(0.5)
        }
    }
}

/// Small gold crown marking a Premium-only control.
struct PremiumBadge: View {
    var body: some View {
        Image(systemName: "crown.fill")
            .font(.caption2)
            .foregroundStyle(.yellow)
            .help("Premium feature")
    }
}
