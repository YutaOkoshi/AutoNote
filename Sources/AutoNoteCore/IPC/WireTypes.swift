import Foundation

public struct StatusResult: Codable, Equatable, Sendable {
    public var recorder: RecorderStatusDTO
    public var queue: [QueueItemDTO]
    public var outputFolderAvailable: Bool

    public init(recorder: RecorderStatusDTO = RecorderStatusDTO(), queue: [QueueItemDTO] = [], outputFolderAvailable: Bool = false) {
        self.recorder = recorder
        self.queue = queue
        self.outputFolderAvailable = outputFolderAvailable
    }
}

public struct RecorderStatusDTO: Codable, Equatable, Sendable {
    /// `idle`, `countdown`, `recording`, `paused` or `grace`.
    public var state: String
    public var meetingID: String?
    public var elapsedSeconds: Int?
    public var device: String?
    public var secondsRemaining: Int?
    public var language: Language?

    public init(state: String = "idle", meetingID: String? = nil, elapsedSeconds: Int? = nil, device: String? = nil,
                secondsRemaining: Int? = nil, language: Language? = nil) {
        self.state = state
        self.meetingID = meetingID
        self.elapsedSeconds = elapsedSeconds
        self.device = device
        self.secondsRemaining = secondsRemaining
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case state, elapsedSeconds, device, secondsRemaining, language
        case meetingID = "meetingId"
    }
}

public struct QueueItemDTO: Codable, Equatable, Sendable {
    public var meetingID: String
    public var stage: String
    /// `JobState` rawValue. Consumers only branch on `"running"` and `awaitingConfirmation`.
    public var state: String
    public var progress: Double?
    public var label: String
    public var message: String?
    public var awaitingConfirmation: Bool
    /// `SummaryFailureKind` rawValue.
    public var summaryFailure: String?
    public var generation: Int
    /// Earliest time a waiting job may run again (retry back-off); `nil` when not delayed.
    public var notBefore: Date?

    public init(meetingID: String = "", stage: String = "", state: String = "", progress: Double? = nil, label: String = "",
                message: String? = nil, awaitingConfirmation: Bool = false, summaryFailure: String? = nil,
                generation: Int = 0, notBefore: Date? = nil) {
        self.meetingID = meetingID
        self.stage = stage
        self.state = state
        self.progress = progress
        self.label = label
        self.message = message
        self.awaitingConfirmation = awaitingConfirmation
        self.summaryFailure = summaryFailure
        self.generation = generation
        self.notBefore = notBefore
    }

    private enum CodingKeys: String, CodingKey {
        case stage, state, progress, label, message, awaitingConfirmation, summaryFailure, generation, notBefore
        case meetingID = "meetingId"
    }
}

public enum MeetingRowState: String, Codable, Sendable {
    case recording, recorded, processing
    case minutesGenerated = "minutes_generated"
    case transcriptOnly = "transcript_only"
    case failed
    case tooShort = "too_short"

    /// The Japanese state word shown in the CLI list and the meeting list UI.
    public func displayText(progressLabel: String?) -> String {
        switch self {
        case .recording: "録音中"
        case .processing: progressLabel ?? "処理中"
        case .minutesGenerated: "完了"
        case .transcriptOnly: "議事録 未生成"
        case .failed: "失敗"
        case .tooShort: "短すぎる録音"
        case .recorded: "録音済み"
        }
    }
}

public struct MeetingRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var durationMinutes: Int?
    /// Whole seconds from the manifest; nil for a meeting known only from the Vault index.
    public var durationSeconds: Int?
    public var state: MeetingRowState
    public var progressLabel: String?
    public var filePath: String?
    public var silenceWarning: Bool
    public var summaryFirstLine: String?

    public init(id: String = "", title: String = "", startedAt: Date = Date(timeIntervalSince1970: 0), durationMinutes: Int? = nil,
                durationSeconds: Int? = nil, state: MeetingRowState = .recorded, progressLabel: String? = nil, filePath: String? = nil,
                silenceWarning: Bool = false, summaryFirstLine: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationMinutes = durationMinutes
        self.durationSeconds = durationSeconds
        self.state = state
        self.progressLabel = progressLabel
        self.filePath = filePath
        self.silenceWarning = silenceWarning
        self.summaryFirstLine = summaryFirstLine
    }
}

public struct AutomationSummary: Codable, Equatable, Sendable {
    public var name: String
    public var on: AutomationTrigger
    public var enabled: Bool
    public var isRunnable: Bool
    public var problem: String?

    public init(name: String = "", on: AutomationTrigger = .minutesGenerated, enabled: Bool = false,
                isRunnable: Bool = false, problem: String? = nil) {
        self.name = name
        self.on = on
        self.enabled = enabled
        self.isRunnable = isRunnable
        self.problem = problem
    }
}

public enum StageLabel {
    public static func text(stage: String, progress: Double?) -> String {
        switch stage {
        case "transcribe":
            if let progress { return "文字起こし中 \(Int((progress * 100).rounded(.down)))%" }
            return "文字起こし中"
        case "summarize": return "議事録生成中"
        case "write_vault": return "Vault に書き出し中"
        case "update_index": return "一覧を更新中"
        case "automations": return "Automations 実行中"
        default: return stage
        }
    }
}
