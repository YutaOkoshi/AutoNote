import AppKit
import AutoNoteCore
import SwiftUI

/// Click, then press the new shortcut. Keys are read with a local `NSEvent` monitor that exists only while the field
/// is recording (inside the app, so no permission is needed). Esc cancels; a key `KeyCombo` cannot store, or a
/// combo without ⌃ ⌥ ⌘, is refused with a message and the old value stays.
struct ShortcutRecorderField: View {
    let combo: KeyCombo?
    /// Shown when `combo` is nil (the stored string does not parse).
    let placeholder: String
    let onRecord: (KeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "キーを押してください（Esc でやめる）" : (combo?.display ?? placeholder))
                    .frame(minWidth: 180)
                    .monospaced(!recording)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if let refusal { Text(refusal).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear { stop() }
        .onWindowResignedKey { stop() }
    }

    private func start() {
        refusal = nil
        recording = true
        guard monitor == nil else { return }
        // Local monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {  // kVK_Escape
            stop()
            return
        }
        let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags))
        guard KeyCombo(parsing: combo.description) == combo else {
            refusal = "このキーはショートカットに使えません（A〜Z、0〜9、F1〜F12）"
            return
        }
        do {
            try combo.validate()
        } catch {
            if case .invalid(let m) = error { refusal = m }
            return
        }
        refusal = nil
        stop()
        onRecord(combo)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= KeyCombo.controlKey }
        if flags.contains(.option) { m |= KeyCombo.optionKey }
        if flags.contains(.shift) { m |= KeyCombo.shiftKey }
        if flags.contains(.command) { m |= KeyCombo.cmdKey }
        return m
    }
}

extension View {
    /// Runs `body` when any window of the app stops being key.
    func onWindowResignedKey(_ body: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in body() }
    }
}
