import Foundation

public struct NoticeButton: Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) { self.id = id; self.title = title }
}

public enum PrivacyPane {
    public static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    public static let systemAudio = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}

/// The wording of `UserNotice.recordingLoss`. "Not arriving" may be a false alarm (an app that keeps its output open
/// in silence looks the same), so it says how to tell and what to do. A failure may also be the disk (a writer).
public enum RecordingLossCopy {
    public static func body(_ track: Track, _ reason: RecordingLossReason) -> String {
        let name = AudioLossPresentation.trackName(track)
        switch reason {
        case .notArriving:
            switch track {
            case .system:
                return "\(name)が 1 分以上録音に入っていません（ほかのアプリは音を出しています）。相手が話しているのにこの通知が出たときは、録音を止めて始め直してください。相手が黙っている・ミュート中なら問題ありません"
            case .mic:
                return "\(name)が 1 分以上録音に入っていません。話しているのにこの通知が出たときは、録音を止めて始め直してください。ミュート中なら問題ありません"
            }
        case .sourceFailed:
            let voice = track == .mic ? "自分の声" : "相手の声"
            let check = track == .mic ? "マイクの許可と機材、ディスクの空き" : "システム音声の録音許可とディスクの空き"
            return "\(name)を録音できていません。この先の\(voice)は録音に入りません。\(check)を確認し、録音を止めて始め直してください"
        }
    }
}

/// What a `UserNotice` looks like as a system notification (and as the window band). Pure data; the App turns it into `UNNotification`s.
public struct NoticeContent: Equatable, Sendable {
    public static let allCategories = [
        "deviceConnectedCountdown", "deviceSeenFirstTime", "deviceAlreadyConnected", "deviceGoneGrace", "silence", "diskLow",
        "recordingTooShort", "interruptedRecordingFound", "minutesGenerated", "transcriptOnly", "claudeNotLoggedIn",
        "overwriteConfirmation", "outputFolderMissing", "automationFailed", "recordingLoss", "recordingNotArriving",
    ]

    /// One notice per category. A system notification gets its buttons from its category, so every notice of a
    /// category must have the buttons of its sample here (the app registers the categories from these).
    public static var categorySamples: [UserNotice] {
        let d = DeviceRef(name: "", uid: "", transport: "")
        let m = MeetingID(rawValue: "")
        return [.deviceConnectedCountdown(d, seconds: 0), .deviceSeenFirstTime(d), .deviceAlreadyConnected(d), .deviceGoneGrace(d, seconds: 0),
                .silence(.mic), .diskLow(availableBytes: 0), .recordingTooShort(m), .interruptedRecordingFound(m),
                .minutesGenerated(m, title: ""), .transcriptOnly(m), .claudeNotLoggedIn(m), .overwriteConfirmation(m),
                .outputFolderMissing, .automationFailed(name: "", m), .recordingLoss(.system, reason: .sourceFailed),
                .recordingLoss(.system, reason: .notArriving)]
    }

    /// `UserNotice.id`.
    public var id: String
    public var category: String
    /// Always "AutoNote".
    public var title: String
    public var body: String
    public var buttons: [NoticeButton]
    /// Everything `action(category:buttonID:userInfo:)` needs, so a tap after an app restart still works.
    public var userInfo: [String: String]

    public init(id: String, category: String, title: String = "AutoNote", body: String, buttons: [NoticeButton] = [], userInfo: [String: String] = [:]) {
        self.id = id; self.category = category; self.title = title; self.body = body; self.buttons = buttons; self.userInfo = userInfo
    }

    /// Notices that need attention rather than a passing banner (the App gives them a time-sensitive interruption level).
    public static func needsAttention(category: String) -> Bool {
        ["recordingTooShort", "interruptedRecordingFound", "overwriteConfirmation", "claudeNotLoggedIn", "recordingLoss",
         "recordingNotArriving"].contains(category)
    }

    public static func make(_ n: UserNotice) -> NoticeContent {
        func c(_ category: String, _ body: String, _ buttons: [(String, String)] = [], _ info: [String: String] = [:]) -> NoticeContent {
            NoticeContent(id: n.id, category: category, body: body, buttons: buttons.map { NoticeButton(id: $0.0, title: $0.1) }, userInfo: info)
        }
        func device(_ d: DeviceRef) -> [String: String] { ["name": d.name, "uid": d.uid, "transport": d.transport] }
        func meeting(_ m: MeetingID) -> [String: String] { ["meeting_id": m.rawValue] }

        switch n {
        case .deviceConnectedCountdown(let d, _): return deviceContent(n, "deviceConnectedCountdown", device(d))
        case .deviceSeenFirstTime(let d): return deviceContent(n, "deviceSeenFirstTime", device(d))
        case .deviceAlreadyConnected(let d): return deviceContent(n, "deviceAlreadyConnected", device(d))
        case .deviceGoneGrace(let d, _): return deviceContent(n, "deviceGoneGrace", device(d))
        case .silence(let t):
            return c("silence", t == .mic ? SilenceMonitor.micMessage : SilenceMonitor.systemMessage, [("openPrivacy", "システム設定を開く")], ["track": t.rawValue])
        case .diskLow(let bytes):
            return c("diskLow", "ディスクの空きが 1GB を切りました（残り \(bytes / 1_048_576) MB）。500MB を切ると録音を止めます")
        case .recordingTooShort(let m):
            return c("recordingTooShort", "1 分未満の短すぎる録音です。文字起こししますか？", [("transcribe", "文字起こしする"), ("discard", "破棄")], meeting(m))
        case .interruptedRecordingFound(let m):
            return c("interruptedRecordingFound", "前回の録音が途中で終わっています。文字起こしと議事録を作りますか？", [("recover", "はい"), ("discard", "破棄")], meeting(m))
        case .minutesGenerated(let m, let title):
            return c("minutesGenerated", "議事録ができました: \(title)", [("open", "開く")], meeting(m))
        case .transcriptOnly(let m):
            return c("transcriptOnly", "議事録 未生成: 文字起こしだけを書き出しました", [("retry", "再実行")], meeting(m))
        case .claudeNotLoggedIn(let m):
            return c("claudeNotLoggedIn", "議事録 未生成: Claude Code にログインしていません。ターミナルで claude を起動してログインしてから再実行してください", [("retry", "再実行")], meeting(m))
        case .overwriteConfirmation(let m):
            return c("overwriteConfirmation", "Vault の会議ファイルがアプリの外で編集されています。上書きしますか？", [("overwrite", "上書きする"), ("keep", "残す")], meeting(m))
        case .outputFolderMissing:
            return c("outputFolderMissing", "保存先が見つかりません")
        case .automationFailed(let name, let m):
            return c("automationFailed", "Automation 失敗: \(name)", [("open", "開く")], meeting(m).merging(["name": name]) { $1 })
        case .recordingLoss(let t, .sourceFailed):
            return c("recordingLoss", RecordingLossCopy.body(t, .sourceFailed), [("openPrivacy", "システム設定を開く")], ["track": t.rawValue])
        case .recordingLoss(let t, .notArriving):
            // Its own category: the permission is not in doubt here, so no button to the settings.
            return c("recordingNotArriving", RecordingLossCopy.body(t, .notArriving), [], ["track": t.rawValue])
        }
    }

    private static func deviceContent(_ n: UserNotice, _ category: String, _ info: [String: String]) -> NoticeContent {
        let titles = DeviceNoticeCopy.actions(for: n).map(\.title)
        return NoticeContent(id: n.id, category: category, body: DeviceNoticeCopy.body(for: n) ?? "",
                             buttons: titles.enumerated().map { NoticeButton(id: "device.\($0.offset)", title: $0.element) }, userInfo: info)
    }

    /// Rebuilds the action from the category, the tapped button (nil: the notification itself) and the stored userInfo only.
    public static func action(category: String, buttonID: String?, userInfo: [String: String]) -> UserNoticeAction? {
        let meetingID = userInfo["meeting_id"].map { MeetingID(rawValue: $0) }
        var device: DeviceRef? {
            guard let name = userInfo["name"], let uid = userInfo["uid"], let transport = userInfo["transport"] else { return nil }
            return DeviceRef(name: name, uid: uid, transport: transport)
        }
        guard let buttonID else { return meetingID.map { .openMeeting($0) } }

        if buttonID.hasPrefix("device."), let d = device, let index = Int(buttonID.dropFirst("device.".count)) {
            let notice: UserNotice? = switch category {
            case "deviceConnectedCountdown": .deviceConnectedCountdown(d, seconds: 0)
            case "deviceSeenFirstTime": .deviceSeenFirstTime(d)
            case "deviceAlreadyConnected": .deviceAlreadyConnected(d)
            default: nil
            }
            guard let notice else { return nil }
            let actions = DeviceNoticeCopy.actions(for: notice)
            return actions.indices.contains(index) ? actions[index].action : nil
        }
        switch (buttonID, meetingID) {
        case ("openPrivacy", _): return .openPrivacySettings
        case ("open", let m?): return .openMeeting(m)
        case ("retry", let m?): return .retry(m)
        case ("transcribe", let m?): return .transcribeTooShort(m)
        case ("discard", let m?): return category == "recordingTooShort" ? .discardTooShort(m) : .discardInterrupted(m)
        case ("recover", let m?): return .recoverInterrupted(m)
        case ("overwrite", let m?): return .resolveOverwrite(m, overwrite: true)
        case ("keep", let m?): return .resolveOverwrite(m, overwrite: false)
        default: return nil
        }
    }
}
