//
//  ScheduleEditor.swift
//  PromptSchedule
//

import SwiftUI

/// Picks a send time and repeat rule (Premium).
struct ScheduleEditor: View {
    @Binding var date: Date?
    @Binding var repeatRule: RepeatRule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Send at a scheduled time", isOn: Binding(
                get: { date != nil },
                set: { date = $0 ? (date ?? Self.defaultDate) : nil }
            ))
            .toggleStyle(.switch)

            if let current = date {
                DatePicker("When", selection: Binding(
                    get: { current },
                    set: { date = $0 }
                ), in: Date()..., displayedComponents: [.date, .hourAndMinute])

                Picker("Repeat", selection: $repeatRule) {
                    ForEach(RepeatRule.allCases) { rule in
                        Text(rule.label).tag(rule)
                    }
                }
            }
        }
    }

    /// The next whole hour.
    static var defaultDate: Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: Date())?.start ?? Date()
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? Date()
    }
}

/// Edits the schedule of a queued prompt.
struct ScheduleSheet: View {
    let item: PromptItem

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date?
    @State private var repeatRule: RepeatRule

    init(item: PromptItem) {
        self.item = item
        _date = State(initialValue: item.scheduledAt ?? ScheduleEditor.defaultDate)
        _repeatRule = State(initialValue: item.repeatRule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule Prompt").font(.title2.bold())
            Text(item.text).lineLimit(3).foregroundStyle(.secondary)
            ScheduleEditor(date: $date, repeatRule: $repeatRule)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    item.scheduledAt = date
                    item.repeatRule = date == nil ? .none : repeatRule
                    item.isArmed = false
                    if item.state == .sent { item.resetTargets() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
