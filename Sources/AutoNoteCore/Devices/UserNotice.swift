import Foundation

/// Every user-facing notice. Copy for non-device cases lives with the code that posts them (and the app).
public enum UserNotice: Equatable, Sendable {
    case deviceConnectedCountdown(DeviceRef, seconds: Int)
    case deviceSeenFirstTime(DeviceRef)
    case deviceAlreadyConnected(DeviceRef)
    case deviceGoneGrace(DeviceRef, seconds: Int)
    case silence(Track)
    case diskLow(availableBytes: Int64)
    case recordingTooShort(MeetingID)
    case interruptedRecordingFound(MeetingID)
    case minutesGenerated(MeetingID, title: String)
    case transcriptOnly(MeetingID)
    case claudeNotLoggedIn(MeetingID)
    case overwriteConfirmation(MeetingID)
    case outputFolderMissing
    case automationFailed(name: String, MeetingID)

    /// The same event always has the same id, so a notice can be withdrawn by it.
    public var id: String {
        switch self {
        case .deviceConnectedCountdown: "device.countdown"
        case .deviceSeenFirstTime(let d): "device.first.\(d.uid)"
        case .deviceAlreadyConnected(let d): "device.connected.\(d.uid)"
        case .deviceGoneGrace: "device.grace"
        case .silence(let t): "silence.\(t.rawValue)"
        case .diskLow: "disk.low"
        case .recordingTooShort(let m): "meeting.tooShort.\(m.rawValue)"
        case .interruptedRecordingFound(let m): "meeting.interrupted.\(m.rawValue)"
        case .minutesGenerated(let m, _): "meeting.minutes.\(m.rawValue)"
        case .transcriptOnly(let m): "meeting.transcriptOnly.\(m.rawValue)"
        case .claudeNotLoggedIn(let m): "meeting.claudeLogin.\(m.rawValue)"
        case .overwriteConfirmation(let m): "meeting.overwrite.\(m.rawValue)"
        case .outputFolderMissing: "output.missing"
        case .automationFailed(let name, let m): "automation.\(name).\(m.rawValue)"
        }
    }
}

public enum RegisterAnswer: Equatable, Sendable { case yes, no, never }

public enum UserNoticeAction: Equatable, Sendable {
    case cancelCountdown
    case startNow(DeviceRef)
    case registerDevice(DeviceRef, answer: RegisterAnswer)
    case openMeeting(MeetingID)
    case retry(MeetingID)
    case resolveOverwrite(MeetingID, overwrite: Bool)
    case transcribeTooShort(MeetingID)
    case discardTooShort(MeetingID)
    case recoverInterrupted(MeetingID)
    case discardInterrupted(MeetingID)
    case openPrivacySettings
}

/// Implemented by the app. Notices carry no sound.
public protocol UserNotifier: Sendable {
    func post(_ notice: UserNotice) async
    func withdraw(id: String) async
}

public enum Banner {
    public static func grace(seconds: Int) -> String { "機材が外れました。\(seconds) 秒後に停止" }
    public static let micFallback = "機材に戻せなかったため、Mac の既定入力で録音を続けています"
    public static let startFailed = "録音を開始できませんでした。マイクの許可と機材を確認してください"
}

/// Copy for the four device notices only; other cases return nil / empty.
public enum DeviceNoticeCopy {
    public static func body(for notice: UserNotice) -> String? {
        switch notice {
        case .deviceConnectedCountdown(let d, let s): "\(d.name)が接続されました。\(s) 秒後に録音を始めます"
        case .deviceSeenFirstTime(let d): "\(d.name)が接続されました。この機材で自動録音しますか？"
        case .deviceAlreadyConnected(let d): "\(d.name)が接続されています。録音を始めますか？"
        case .deviceGoneGrace(_, let s): Banner.grace(seconds: s)
        default: nil
        }
    }

    public static func actions(for notice: UserNotice) -> [(title: String, action: UserNoticeAction)] {
        switch notice {
        case .deviceConnectedCountdown: [("取り消す", .cancelCountdown)]
        case .deviceSeenFirstTime(let d): [("はい", .registerDevice(d, answer: .yes)), ("いいえ", .registerDevice(d, answer: .no)), ("今後聞かない", .registerDevice(d, answer: .never))]
        case .deviceAlreadyConnected(let d): [("開始", .startNow(d))]
        default: []
        }
    }

    public static func isSticky(_ notice: UserNotice) -> Bool {
        if case .deviceAlreadyConnected = notice { true } else { false }
    }
}
