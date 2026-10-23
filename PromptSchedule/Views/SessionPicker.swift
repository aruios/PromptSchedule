//
//  SessionPicker.swift
//  PromptSchedule
//

import SwiftUI

/// Dropdown-style button that opens a checkbox list of running Claude sessions.
struct SessionPicker: View {
    let sessions: [ClaudeSession]
    @Binding var selection: Set<Int32>
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
                    Text("No Claude sessions running in Terminal.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Select All") { selection = Set(sessions.map(\.id)) }
                        Button("None") { selection.removeAll() }
                    }
                    .buttonStyle(.link)
                    Divider()
                    ForEach(sessions) { session in
                        Toggle(isOn: binding(for: session.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.folderName)
                                Text("\(session.shortTTY) · pid \(session.pid)\(session.cwd.map { " · \($0)" } ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .padding()
            .frame(minWidth: 280, maxWidth: 420, alignment: .leading)
        }
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
