import AutoNoteCore
import Carbon.HIToolbox
import Foundation
import os

private let logger = Logger(subsystem: AppIdentity.bundleID, category: "HotKeyCenter")

/// Global shortcuts through Carbon `RegisterEventHotKey`. Needs no accessibility permission.
@MainActor
final class HotKeyCenter {
    /// 'ANOT'
    private static let signature: OSType = 0x414E_4F54

    private let onPress: @MainActor (ShortcutAction) -> Void
    private var registered: [EventHotKeyRef] = []
    private var actions: [UInt32: ShortcutAction] = [:]
    private var handler: EventHandlerRef?

    init(onPress: @escaping @MainActor (ShortcutAction) -> Void) {
        self.onPress = onPress
        installHandler()
    }

    /// Unregisters every previous hot key and registers the readable ones of `s`. Returns the `RegisterEventHotKey`
    /// status per action; an unreadable string is not registered and not in the result.
    @discardableResult
    func apply(_ s: Shortcuts) -> [ShortcutAction: OSStatus] {
        for ref in registered { UnregisterEventHotKey(ref) }
        registered = []
        actions = [:]

        let bindings = ShortcutBindings(s)
        var result: [ShortcutAction: OSStatus] = [:]
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let combo = bindings.combo(for: action) else {
                logger.error("hotkey \(action.rawValue, privacy: .public): unreadable \(s[keyPath: action.keyPath], privacy: .public)")
                continue
            }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetEventDispatcherTarget(), 0, &ref)
            result[action] = status
            if status == noErr, let ref {
                registered.append(ref)
                actions[id] = action
                logger.info("hotkey \(action.rawValue, privacy: .public) registered as \(combo.description, privacy: .public)")
            } else {
                logger.error("hotkey \(action.rawValue, privacy: .public) (\(combo.description, privacy: .public)) failed: \(status)")
            }
        }
        return result
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard read == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // Carbon delivers hot-key events on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().pressed(id)
            }
            return noErr
        }, 1, &spec, me, &handler)
        if status != noErr { logger.error("InstallEventHandler failed: \(status)") }
    }

    private func pressed(_ id: UInt32) {
        guard let action = actions[id] else { return }
        logger.notice("hotkey pressed: \(action.rawValue, privacy: .public)")
        onPress(action)
    }
}
