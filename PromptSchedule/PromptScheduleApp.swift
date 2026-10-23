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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PromptItem.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        Window("PromptSchedule", id: "main") {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 980, height: 680)
    }
}
