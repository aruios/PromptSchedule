//
//  Premium.swift
//  PromptSchedule
//

import Foundation
import UserNotifications

/// Premium is a simple switch for now; licensing will replace it later.
enum Premium {
    static let key = "isPremium"
    static let autopilotKey = "autopilot"
    static let reframeStyleKey = "reframeStyle"
    static let customReframeKey = "customReframeInstructions"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
    static var isAutopilotOn: Bool { isOn && UserDefaults.standard.bool(forKey: autopilotKey) }
}

/// "Claude finished" notifications (Premium).
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
