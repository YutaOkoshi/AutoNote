import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (spec §15). Never touched when the data directory is overridden
/// (E2E and development runs; ruling X22) — the caller checks that.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Registers (`true`) or unregisters (`false`) the app as a login item. When macOS needs the user's approval
    /// the Login Items pane is opened.
    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            if service.status != .enabled { try service.register() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    /// True when the setting and the system disagree.
    static func needsReconciling(launchAtLogin: Bool) -> Bool {
        switch status {
        case .enabled: !launchAtLogin
        case .requiresApproval: !launchAtLogin
        case .notRegistered, .notFound: launchAtLogin
        @unknown default: false
        }
    }

    /// Brings the system in line with `launchAtLogin`; failures are logged, never thrown.
    static func reconcile(launchAtLogin: Bool) {
        guard needsReconciling(launchAtLogin: launchAtLogin) else { return }
        do {
            try set(launchAtLogin)
            NSLog("AutoNote: login item %@", launchAtLogin ? "registered" : "unregistered")
        } catch {
            NSLog("AutoNote: login item update failed: %@", String(describing: error))
        }
    }
}
