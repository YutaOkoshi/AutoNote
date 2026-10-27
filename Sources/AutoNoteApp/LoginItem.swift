import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (spec §15). Never touched when the data directory is overridden
/// (E2E and development runs; ruling X22) — the caller checks that.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// What a reconciliation did, for the settings screen to show next to the toggle (13b review Minor 6).
    enum Outcome: Equatable {
        /// The system already matched the setting.
        case unchanged
        case updated
        /// `AUTONOTE_DATA_DIR` is set; `SMAppService` was not touched (ruling X22).
        case leftAlone
        /// macOS waits for the user's approval. `openedSettings` is true when this call already opened the pane.
        case requiresApproval(openedSettings: Bool)
        case failed(String)
    }

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

    /// Brings the system in line with `launchAtLogin`; failures are logged and returned, never thrown.
    @discardableResult
    static func reconcile(launchAtLogin: Bool) -> Outcome {
        guard needsReconciling(launchAtLogin: launchAtLogin) else {
            return launchAtLogin && status == .requiresApproval ? .requiresApproval(openedSettings: false) : .unchanged
        }
        do {
            try set(launchAtLogin)
            NSLog("AutoNote: login item %@", launchAtLogin ? "registered" : "unregistered")
            return launchAtLogin && status == .requiresApproval ? .requiresApproval(openedSettings: true) : .updated
        } catch {
            NSLog("AutoNote: login item update failed: %@", String(describing: error))
            return .failed(describe(error))
        }
    }

    /// `SMAppService` errors are `NSError`s in the `SMAppServiceErrorDomain`; `.notFound` is what a build outside
    /// /Applications usually gets.
    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        if (ns.domain == SMAppServiceErrorDomain && ns.code == Int(kSMErrorJobNotFound)) || status == .notFound {
            return "ログイン項目に登録できません（アプリを「アプリケーション」フォルダに置いてからやり直してください）"
        }
        return "ログイン項目を変更できません（\(ns.localizedDescription)）"
    }
}
