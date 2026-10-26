import AppKit
import AutoNoteCore
import Foundation
import UserNotifications

/// Posts `UserNotice`s as silent system notifications with action buttons and routes taps back as `UserNoticeAction`s.
@MainActor
final class SystemUserNotifier: NSObject, UserNotifier, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let onAction: @MainActor (UserNoticeAction, _ category: String) -> Void
    private let onPost: @MainActor (UserNotice) -> Void
    private let onWithdraw: @MainActor (String) -> Void

    init(onAction: @escaping @MainActor (UserNoticeAction, _ category: String) -> Void,
         onPost: @escaping @MainActor (UserNotice) -> Void,
         onWithdraw: @escaping @MainActor (String) -> Void) {
        self.onAction = onAction
        self.onPost = onPost
        self.onWithdraw = onWithdraw
        super.init()
        center.delegate = self
        registerCategories()
    }

    /// One category per notice case, with the buttons that case has. Buttons for the device cases depend only on the case.
    private func registerCategories() {
        let samples = Self.sampleNotices()
        let categories = samples.map { n -> UNNotificationCategory in
            let content = NoticeContent.make(n)
            let actions = content.buttons.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground]) }
            return UNNotificationCategory(identifier: content.category, actions: actions, intentIdentifiers: [], options: [])
        }
        center.setNotificationCategories(Set(categories))
    }

    private static func sampleNotices() -> [UserNotice] {
        let d = DeviceRef(name: "", uid: "", transport: "")
        let m = MeetingID(rawValue: "")
        return [.deviceConnectedCountdown(d, seconds: 0), .deviceSeenFirstTime(d), .deviceAlreadyConnected(d), .deviceGoneGrace(d, seconds: 0),
                .silence(.mic), .diskLow(availableBytes: 0), .recordingTooShort(m), .interruptedRecordingFound(m),
                .minutesGenerated(m, title: ""), .transcriptOnly(m), .claudeNotLoggedIn(m), .overwriteConfirmation(m),
                .outputFolderMissing, .automationFailed(name: "", m)]
    }

    /// Asks for alerts only (no sound, no badge). A denial is logged, not thrown: the window band is the fallback surface.
    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert])
            NSLog("AutoNote: notification authorization granted=%@", granted ? "true" : "false")
        } catch {
            NSLog("AutoNote: notification authorization failed: %@", String(describing: error))
        }
    }

    func post(_ notice: UserNotice) async {
        let content = NoticeContent.make(notice)
        let u = UNMutableNotificationContent()
        u.title = content.title
        u.body = content.body
        u.categoryIdentifier = content.category
        u.userInfo = content.userInfo
        u.sound = nil
        // Time-sensitive (never critical) only where the plan marks the notice as needing attention.
        u.interruptionLevel = NoticeContent.needsAttention(category: content.category) ? .timeSensitive : .active
        let request = UNNotificationRequest(identifier: content.id, content: u, trigger: nil)
        do { try await center.add(request) } catch { NSLog("AutoNote: could not post notice %@: %@", content.id, String(describing: error)) }
        onPost(notice)
    }

    func withdraw(id: String) async {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        onWithdraw(id)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let info = response.notification.request.content.userInfo.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let tapped = response.actionIdentifier
        let buttonID: String? = tapped == UNNotificationDefaultActionIdentifier || tapped == UNNotificationDismissActionIdentifier ? nil : tapped
        let isDismiss = tapped == UNNotificationDismissActionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            if isDismiss { return }
            if let action = NoticeContent.action(category: category, buttonID: buttonID, userInfo: info) {
                if action == .openPrivacySettings {
                    NSWorkspace.shared.open(info["track"] == "system" ? PrivacyPane.systemAudio : PrivacyPane.microphone)
                }
                self.onAction(action, category)
            } else if buttonID == nil {
                // A plain tap with no meeting: the owner opens the window (it receives no action).
                NSApp.activate()
            }
        }
    }
}
