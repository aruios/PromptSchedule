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
    @Environment(Dispatcher.self) private var dispatcher
    @Query(sort: \PromptItem.createdAt) private var items: [PromptItem]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]

    @AppStorage(Premium.key) private var isPremium = false
    @AppStorage(Premium.autopilotKey) private var isAutopilotOn = false

    @State private var selectedSessions: Set<Int32> = []
    @State private var draft = ""
    @State private var draftOriginal: String?
    @State private var draftSchedule: Date?
    @State private var draftRepeat: RepeatRule = .none
    @State private var isSchedulePopoverOpen = false
    @State private var tableSelection: Set<PersistentIdentifier> = []
    @State private var sheet: SheetRequest?
    @State private var upsell: String?
    @State private var isStartSessionPromptShown = false
    /// A session we just launched, to select automatically once it shows up.
    @State private var pendingLaunch: (folder: String, existing: Set<Int32>)?

    private enum SheetRequest: Identifiable {
        case composerReframe
        case edit(PromptItem)
        case schedule(PromptItem)
        case fillTemplate(PromptTemplate)
        case saveTemplate
        case manageTemplates
        case newSession

        var id: String {
            switch self {
            case .composerReframe: "composer"
            case .edit(let item): "edit-\(item.persistentModelID.hashValue)"
            case .schedule(let item): "schedule-\(item.persistentModelID.hashValue)"
            case .fillTemplate(let template): "fill-\(template.persistentModelID.hashValue)"
            case .saveTemplate: "save-template"
            case .manageTemplates: "manage-templates"
            case .newSession: "new-session"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            composer
            Divider()
            queueTable
        }
        .frame(minWidth: 900, minHeight: 580)
        .toolbar { toolbar }
        .sheet(item: $sheet, content: sheetContent)
        .alert("Premium feature", isPresented: Binding(get: { upsell != nil }, set: { if !$0 { upsell = nil } })) {
            Button("Turn On Premium") { setPremium(true) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("\(upsell ?? "This") is part of Premium. Turn on Premium with the button at the top to use it.")
        }
        .alert("No Claude sessions running", isPresented: $isStartSessionPromptShown) {
            Button("Start New Session") { sheet = .newSession }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("PromptSchedule sends prompts to Claude Code sessions, and none are running. Do you want to start a new session?")
        }
        .task {
            // Ask once the first scan is in, so we don't ask before sessions are found.
            while !dispatcher.hasScanned { try? await Task.sleep(for: .milliseconds(200)) }
            if dispatcher.sessions.isEmpty { isStartSessionPromptShown = true }
        }
        .onChange(of: dispatcher.sessions) {
            selectedSessions.formIntersection(Set(dispatcher.sessions.map(\.id)))
            selectLaunchedSession()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Send to:").foregroundStyle(.secondary)
            SessionPicker(sessions: dispatcher.sessions, selection: $selectedSessions, isPremium: isPremium)
            Button {
                Task { await dispatcher.refreshSessions() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh running sessions")
            Button {
                sheet = .newSession
            } label: {
                Label("New Session", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Start a new Claude Code session in a terminal")
            Text(dispatcher.sessions.isEmpty ? "None running" : "\(dispatcher.sessions.count) running")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            autopilotToggle
            premiumButton
        }
        .padding([.horizontal, .top])
    }

    private var autopilotToggle: some View {
        Toggle(isOn: Binding(
            get: { isPremium && isAutopilotOn },
            set: { newValue in
                guard isPremium else { upsell = "Autopilot"; return }
                isAutopilotOn = newValue
            }
        )) {
            HStack(spacing: 4) {
                Text("Autopilot")
                if !isPremium { PremiumBadge() }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Send queued prompts automatically, each one when its session has finished the previous task")
    }

    private var premiumButton: some View {
        Button {
            setPremium(!isPremium)
        } label: {
            Label(isPremium ? "Premium On" : "Premium", systemImage: isPremium ? "crown.fill" : "crown")
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(isPremium ? .orange : .gray)
        .help(isPremium ? "Premium features are on. Click to switch them off." : "Switch on Premium features")
    }

    private func setPremium(_ on: Bool) {
        isPremium = on
        HotKey.shared.setEnabled(on)
        if on { Notifier.requestAuthorization() }
    }

    // MARK: - Composer

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
                templatesMenu
                scheduleButton

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
                    sheet = .composerReframe
                } label: {
                    Label("Reframe", systemImage: "sparkles")
                }
                .disabled(trimmedDraft.isEmpty)

                Button(draftSchedule == nil ? "Add to Queue" : "Schedule") { addDraft(sendNow: false) }
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

    @ViewBuilder
    private var templatesMenu: some View {
        if isPremium {
            Menu {
                ForEach(templates) { template in
                    Button(template.name) { useTemplate(template) }
                }
                if !templates.isEmpty { Divider() }
                Button("Save Prompt as Template…") { sheet = .saveTemplate }
                    .disabled(trimmedDraft.isEmpty)
                Button("Manage Templates…") { sheet = .manageTemplates }
            } label: {
                Label("Templates", systemImage: "doc.text")
            }
            .fixedSize()
        } else {
            Button { upsell = "Prompt templates" } label: {
                Label("Templates", systemImage: "doc.text")
                PremiumBadge()
            }
        }
    }

    private var scheduleButton: some View {
        Button {
            if isPremium { isSchedulePopoverOpen = true } else { upsell = "Scheduling" }
        } label: {
            if let draftSchedule {
                Label(scheduleText(draftSchedule, draftRepeat), systemImage: "calendar.badge.clock")
            } else {
                Label("Schedule", systemImage: "calendar.badge.clock")
            }
            if !isPremium { PremiumBadge() }
        }
        .popover(isPresented: $isSchedulePopoverOpen, arrowEdge: .bottom) {
            ScheduleEditor(date: $draftSchedule, repeatRule: $draftRepeat)
                .padding()
                .frame(width: 360)
        }
    }

    // MARK: - Queue table

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

            TableColumn("When") { item in
                if let scheduledAt = item.scheduledAt {
                    Text(scheduleText(scheduledAt, item.repeatRule))
                        .foregroundStyle(isPremium ? .primary : .secondary)
                        .help(isPremium ? "" : "Scheduled sends are paused while Premium is off")
                } else {
                    Text("Manual").foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("Status") { item in
                HStack(spacing: 4) {
                    StateIcon(state: item.state)
                    Text(statusText(for: item))
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("") { item in
                HStack(spacing: 6) {
                    Button { dispatcher.send([item]) } label: {
                        Image(systemName: item.state == .failed ? "arrow.clockwise" : "paperplane")
                    }
                    .help(item.state == .failed ? "Retry failed sessions" : "Send now")
                    .disabled(isBusy(item))

                    Button { sheet = .edit(item) } label: { Image(systemName: "pencil") }
                        .help("Edit / Reframe")
                        .disabled(isBusy(item))

                    Button { delete([item]) } label: { Image(systemName: "trash") }
                        .help("Delete")
                        .disabled(item.state == .sending)
                }
                .buttonStyle(.borderless)
            }
            .width(80)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            let chosen = items.filter { ids.contains($0.persistentModelID) }
            Button("Send Now") { dispatcher.send(chosen) }
            if chosen.count == 1, let item = chosen.first {
                Button("Edit / Reframe…") { sheet = .edit(item) }
                Button("Schedule…") {
                    if isPremium { sheet = .schedule(item) } else { upsell = "Scheduling" }
                }
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
                dispatcher.send(items.filter { $0.state == .queued && !$0.isArmed && $0.scheduledAt == nil })
            } label: {
                Label("Send All Queued (\(queuedCount))", systemImage: "paperplane.circle.fill")
            }
            .disabled(queuedCount == 0)
            .help("Send every queued prompt, in order")

            Button {
                delete(items.filter { $0.state == .sent && $0.scheduledAt == nil })
            } label: {
                Label("Clear Sent", systemImage: "checkmark.circle.badge.xmark")
            }
            .disabled(!items.contains { $0.state == .sent && $0.scheduledAt == nil })
            .help("Remove prompts that were delivered")
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ request: SheetRequest) -> some View {
        switch request {
        case .composerReframe:
            ReframeSheet(original: draftOriginal ?? draft, startReframing: true) { text in
                if draftOriginal == nil { draftOriginal = draft }
                draft = text
            }
        case .edit(let item):
            ReframeSheet(original: item.originalText ?? item.text, current: item.text, startReframing: false) { text in
                if item.originalText == nil { item.originalText = item.text }
                item.text = text
                // An edited prompt goes back into the queue.
                item.resetTargets()
                item.isArmed = false
                item.sentAt = nil
            }
        case .schedule(let item):
            ScheduleSheet(item: item)
        case .fillTemplate(let template):
            TemplateFillSheet(template: template) { text in insertIntoDraft(text) }
        case .saveTemplate:
            SaveTemplateSheet(text: trimmedDraft)
        case .manageTemplates:
            ManageTemplatesSheet()
        case .newSession:
            NewSessionSheet(runningFolders: dispatcher.sessions.compactMap(\.cwd)) { folder in
                pendingLaunch = (folder, Set(dispatcher.sessions.map(\.id)))
            }
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
        items.filter { $0.state == .queued && !$0.isArmed && $0.scheduledAt == nil }.count
    }

    private var selectedTargets: [PromptTarget] {
        dispatcher.sessions.filter { selectedSessions.contains($0.id) }.map(PromptTarget.init)
    }

    private func isBusy(_ item: PromptItem) -> Bool {
        item.state == .sending || item.isArmed
    }

    private func addDraft(sendNow: Bool) {
        let original = draftOriginal.flatMap { $0 == draft ? nil : $0 }
        let item = PromptItem(text: trimmedDraft, originalText: original, targets: selectedTargets)
        if !sendNow, isPremium, let draftSchedule {
            item.scheduledAt = draftSchedule
            item.repeatRule = draftRepeat
        }
        modelContext.insert(item)
        draft = ""
        draftOriginal = nil
        draftSchedule = nil
        draftRepeat = .none
        if sendNow { dispatcher.send([item]) }
    }

    /// Selects the session we launched as soon as the scanner finds it.
    private func selectLaunchedSession() {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        guard let pending = pendingLaunch,
              let session = dispatcher.sessions.first(where: {
                  !pending.existing.contains($0.id) && $0.cwd.map(resolved) == resolved(pending.folder)
              })
        else { return }
        selectedSessions.insert(session.id)
        pendingLaunch = nil
    }

    private func useTemplate(_ template: PromptTemplate) {
        if TemplateEngine.userVariables(in: template.body).isEmpty {
            insertIntoDraft(template.body)
        } else {
            sheet = .fillTemplate(template)
        }
    }

    private func insertIntoDraft(_ text: String) {
        draft = trimmedDraft.isEmpty ? text : draft + "\n\n" + text
        draftOriginal = nil
    }

    private func retarget(_ chosen: [PromptItem]) {
        for item in chosen where !isBusy(item) {
            item.targets = selectedTargets
            item.sentAt = nil
        }
    }

    private func delete(_ chosen: [PromptItem]) {
        for item in chosen where item.state != .sending {
            modelContext.delete(item)
        }
    }

    private func scheduleText(_ date: Date, _ rule: RepeatRule) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(date) ? "Today"
            : Calendar.current.isDateInTomorrow(date) ? "Tomorrow"
            : date.formatted(.dateTime.month(.abbreviated).day())
        switch rule {
        case .none: return "\(day) \(time)"
        case .hourly: return "Hourly, next \(time)"
        default: return "\(rule.label), \(time)"
        }
    }

    private func statusText(for item: PromptItem) -> String {
        switch item.state {
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .failed:
            let failed = item.targets.filter { $0.state == .failed }.count
            return "Failed \(failed)/\(item.targets.count)"
        case .queued:
            if dispatcher.isWaiting(item) {
                return isPremium ? "Waiting for idle" : "Waiting"
            }
            if item.scheduledAt != nil { return isPremium ? "Scheduled" : "Paused" }
            return isAutopilotOn && isPremium ? "Autopilot" : "Queued"
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
    let container = try! ModelContainer(
        for: PromptItem.self, PromptTemplate.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ContentView()
        .modelContainer(container)
        .environment(Dispatcher(container: container))
}
