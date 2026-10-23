//
//  HotKey.swift
//  PromptSchedule
//

import AppKit
import Carbon.HIToolbox

/// System-wide ⌃⌥⌘P shortcut that opens the quick-send panel (Premium).
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotKey {
    static let shared = HotKey()
    static let displayString = "⌃⌥⌘P"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var action: () -> Void = {}

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled, hotKeyRef == nil {
            register()
        } else if !enabled, hotKeyRef != nil {
            unregister()
        }
    }

    private func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.shared.action() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5053_4348), id: 1) // "PSCH"
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
