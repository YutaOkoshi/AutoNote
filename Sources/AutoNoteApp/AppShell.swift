import AppKit
import AutoNoteCore
import Observation
import SwiftUI
import os

private let logger = Logger(subsystem: AppIdentity.bundleID, category: "AppShell")

/// What the scenes need from the delegate: the environment once it is built, and a way to open a window from
/// outside a view (notification taps, launch item 4). SwiftUI's `openWindow` exists only inside views, so the
/// menu-bar label hands it over when it first appears; requests made before that wait in `pending`.
@MainActor @Observable
final class AppShell {
    static let mainWindowID = "main"

    /// Nil until `AppEnvironment.make` finishes.
    var env: AppEnvironment?

    /// True while the main window is on screen (`MainWindow`'s `onAppear` / `onDisappear`). Minutes that finish while
    /// it is open are selected there; the window is never opened or brought forward for them.
    @ObservationIgnored var isMainWindowOpen = false

    /// The settings tab to show. `showSettings` sets it; the settings window binds its `TabView` to it.
    var settingsTab: SettingsTab = .general

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var pending: [String] = []

    /// Called from the label's body, so it only stores the action and defers opening to the next main-queue turn.
    func install(_ action: OpenWindowAction) {
        let first = openWindowAction == nil
        openWindowAction = action
        if first { logger.info("openWindow installed") }
        guard !pending.isEmpty else { return }
        let ids = pending
        pending = []
        DispatchQueue.main.async {
            for id in ids { action(id: id) }
        }
    }

    /// Brings the app forward (it is `LSUIElement`; ruling X37) and opens the window with `id`.
    func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        logger.info("open window \(id, privacy: .public)")
        if let openWindowAction {
            openWindowAction(id: id)
        } else if !pending.contains(id) {
            pending.append(id)
        }
    }

    /// Opens the settings window on `tab`. Nothing is saved.
    func showSettings(_ tab: SettingsTab, using openSettings: OpenSettingsAction) {
        settingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}
