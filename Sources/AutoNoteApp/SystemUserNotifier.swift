import AppKit
import AutoNoteCore
import Foundation
import UserNotifications

/// Posts `UserNotice`s as silent system notifications with action buttons and routes taps back as `UserNoticeAction`s.
///
/// Created synchronously at the start of `applicationDidFinishLaunching` so the center's delegate exists before a
/// tap that cold-launched the app is delivered (M9). The callbacks are bound later (`bind`), once the services
/// exist; taps that arrive before that are kept and replayed on `bind`.
@MainActor
final class SystemUserNotifier: NSObject, UserNotifier, UNUserNotificationCenterDelegate {
    struct Handlers {
        var onAction: @MainActor (UserNoticeAction, _ category: String) -> Void
        var onPost: @MainActor (UserNotice) -> Void
        var onWithdraw: @MainActor (String) -> Void
        var onOpenWindow: @MainActor () -> Void
    }

    private let center = UNUserNotificationCenter.current()
    private var handlers: Handlers?
    private var pending: [@MainActor (Handlers) -> Void] = []

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    /// Binds the callbacks and replays the taps that arrived before.
    func bind(_ handlers: Handlers) {
        self.handlers = handlers
        let replay = pending
        pending = []
        for tap in replay { tap(handlers) }
    }

    private func withHandlers(_ body: @escaping @MainActor (Handlers) -> Void) {
        if let handlers { body(handlers) } else { pending.append(body) }
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
        do { try await center.add(request) } catch {
            // Denied or failed: the window band is the fallback surface, so the model hears about it anyway (I1).
            NSLog("AutoNote: could not post notice %@: %@", content.id, String(describing: error))
        }
        handlers?.onPost(notice)
    }

    func withdraw(id: String) async {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        handlers?.onWithdraw(id)
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
                self.withHandlers { $0.onAction(action, category) }
            } else if buttonID == nil {
                // A plain tap with no meeting opens the window (the app is LSUIElement, so activating alone shows nothing).
                self.withHandlers { $0.onOpenWindow() }
            }
        }
    }
}
