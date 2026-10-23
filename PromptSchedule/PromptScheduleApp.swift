//
//  PromptScheduleApp.swift
//  PromptSchedule
//
//  Created by Arun Madasamy on 10/23/26.
//

import SwiftUI
import SwiftData

@main
struct PromptScheduleApp: App {
    let sharedModelContainer: ModelContainer
    @State private var dispatcher: Dispatcher
    @AppStorage(Premium.key) private var isPremium = false

    init() {
        let schema = Schema([
            PromptItem.self,
            PromptTemplate.self,
        ])
        // Unit tests run inside the app: keep them away from the real queue and sessions.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isTesting)

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        Self.seedTemplates(in: container)

        let dispatcher = Dispatcher(container: container, autoStart: !isTesting)
        Notifier.configure()
        sharedModelContainer = container
        _dispatcher = State(initialValue: dispatcher)
        QuickSendPanel.shared.configure(dispatcher: dispatcher, container: container)
        HotKey.shared.setEnabled(Premium.isOn)
    }

    var body: some Scene {
        Window("PromptSchedule", id: "main") {
            ContentView()
                .environment(dispatcher)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1040, height: 700)

        // Premium: quick send from the menu bar.
        MenuBarExtra("PromptSchedule", systemImage: "paperplane.fill", isInserted: $isPremium) {
            QuickSendView()
                .environment(dispatcher)
                .modelContainer(sharedModelContainer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    /// Adds the starter templates once, on first launch.
    private static func seedTemplates(in container: ModelContainer) {
        let key = "didSeedTemplates"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for (name, body) in PromptTemplate.starters {
            container.mainContext.insert(PromptTemplate(name: name, body: body))
        }
        try? container.mainContext.save()
        UserDefaults.standard.set(true, forKey: key)
    }
}
