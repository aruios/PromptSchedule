//
//  Premium.swift
//  PromptSchedule
//

import AppKit
import Observation
import SwiftData
import UserNotifications

/// Premium is a simple switch for now; licensing will replace it later.
enum Premium {
    static let key = "isPremium"
    static let autopilotKey = "autopilot"
    static let reframeStyleKey = "reframeStyle"
    static let customReframeKey = "customReframeInstructions"
    static let aiSummariesKey = "aiSummaries"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
    static var isAutopilotOn: Bool { isOn && UserDefaults.standard.bool(forKey: autopilotKey) }
    static var isAISummariesOn: Bool { isOn && UserDefaults.standard.bool(forKey: aiSummariesKey) }
}

/// Requests from outside the window (notification buttons) for the main window to act on.
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Request: Equatable {
        case showResult(PersistentIdentifier)
        case followUp(pid: Int32)
    }

    var request: Request?

    private init() {}
}

/// Task-result notifications (Premium), with Show and Follow Up buttons.
enum Notifier {
    static let resultCategory = "taskResult"
    private static let showAction = "show"
    private static let followUpAction = "followUp"

    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: resultCategory,
                actions: [
                    UNNotificationAction(identifier: showAction, title: "Show Result", options: [.foreground]),
                    UNNotificationAction(identifier: followUpAction, title: "Follow Up", options: [.foreground]),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, item: PromptItem? = nil, pid: Int32? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let item, let pid,
           let id = try? JSONEncoder().encode(item.persistentModelID) {
            content.categoryIdentifier = resultCategory
            content.userInfo = ["item": id.base64EncodedString(), "pid": Int(pid)]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Routes notification clicks to the main window.
    fileprivate static func handle(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        let pid = (userInfo["pid"] as? Int).map(Int32.init)
        let item = (userInfo["item"] as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode(PersistentIdentifier.self, from: $0) }

        NSApp.activate()
        if actionIdentifier == followUpAction, let pid {
            AppRouter.shared.request = .followUp(pid: pid)
        } else if let item {
            AppRouter.shared.request = .showResult(item)
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    // Show banners even while PromptSchedule is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        // userInfo holds only plist values (strings and numbers), so it's safe to hand over.
        nonisolated(unsafe) let info = userInfo
        await MainActor.run {
            Notifier.handle(actionIdentifier: action, userInfo: info)
        }
    }
}
