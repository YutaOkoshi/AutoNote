import Foundation

/// The one error type the UI and the CLI see from a port. `CommandRouter` (Task 9) maps it to the wire.
public enum AppCommandError: Error, Equatable, Sendable {
    case notRecording, alreadyRecording, notFound(String), invalid(String), failed(String)
}

public enum RecorderCommand: Sendable { case start, stop, pause, resume, bookmark }

/// Which recorder commands are allowed in which state (spec §5.4, §5.9). Ports check this before acting.
public enum RecorderCommandRules {
    public static func check(_ c: RecorderCommand, state: RecorderState) throws(AppCommandError) {
        switch c {
        case .start:
            // From the countdown a manual start discards the countdown (§5.9).
            if [.recording, .paused, .grace].contains(state) { throw .alreadyRecording }
        case .stop, .bookmark:
            if [.idle, .countdown].contains(state) { throw .notRecording }
        case .pause:
            switch state {
            case .recording: return
            case .idle, .countdown: throw .notRecording
            case .paused: throw .invalid("すでに一時停止中です")
            case .grace: throw .invalid("機材が外れているあいだは一時停止できません")
            }
        case .resume:
            switch state {
            case .paused: return
            case .idle, .countdown: throw .notRecording
            case .recording, .grace: throw .invalid("一時停止中ではありません")
            }
        }
    }
}

public protocol RecorderPort: Sendable {
    func current() async -> RecorderSnapshot
    func snapshots() async -> AsyncStream<RecorderSnapshot>
    /// The meeting timeline position (`RecordingSession.elapsed()`); nil when not recording (ruling X25).
    func elapsed() async -> TimelineTime?
    /// The last second's peak per track (`RecordingSession.levels()`), read on the existing 1-second tick; `[]` when idle.
    func levels() async -> [TrackLevel]
    func start(language: Language?) async throws
    func stop() async throws
    func pause() async throws
    func resume() async throws
    func bookmark(note: String?) async throws -> Bookmark
    func cancelCountdown() async
    func setLanguage(_ l: Language) async
    func handleNotice(_ action: UserNoticeAction) async
}

public protocol RecordingEventsPort: Sendable {
    func events() async -> AsyncStream<RecordingEvent>
}

public struct QueueStatus: Equatable, Sendable {
    /// Every job in the queue snapshot, including done jobs that carry a `summaryFailure` (ruling X15).
    public var items: [QueueItemDTO]
    public var pausedForRecording: Bool

    public init(items: [QueueItemDTO] = [], pausedForRecording: Bool = false) {
        self.items = items
        self.pausedForRecording = pausedForRecording
    }

    public static let empty = QueueStatus()
}

public protocol QueuePort: Sendable {
    func status() async -> QueueStatus
    func updates() async -> AsyncStream<QueueStatus>
    func retry(_ id: MeetingID) async throws
    func regenerate(_ id: MeetingID) async throws
    func resolveOverwrite(_ id: MeetingID, overwrite: Bool) async throws
    func acceptShortRecording(_ id: MeetingID) async throws
    func delete(_ id: MeetingID) async throws
}

public enum SaveMinutesOutcome: Equatable, Sendable {
    case saved(URL)
    /// The Vault file was edited outside AutoNote; nothing was saved (`minutes.json`, the manifest title and the
    /// Vault file are left alone) until the caller saves again with `overwrite: true`.
    case externallyEdited(URL)
}

public protocol MeetingsPort: Sendable {
    func rows() async throws -> [MeetingRow]
    func latestMinutesFile() async throws -> URL?
    func manifest(_ id: MeetingID) async throws -> Manifest
    func minutes(_ id: MeetingID) async throws -> MinutesOutput?
    func transcript(_ id: MeetingID, kind: TranscriptKind) async throws -> Transcript?
    func saveMinutes(_ id: MeetingID, _ m: MinutesOutput, renameFile: Bool, overwrite: Bool) async throws -> SaveMinutesOutcome
    func importAudio(_ file: URL, startedAt: Date?) async throws -> MeetingID
    func recover(_ id: MeetingID) async throws
    func discard(_ id: MeetingID) async throws
}

public protocol AutomationsPort: Sendable {
    func summaries() async -> ([AutomationSummary], warnings: [String])
    func run(name: String, meetingID: MeetingID) async throws -> AutomationRunRecord
    func recentRuns(limit: Int) async -> [AutomationRunRecord]
    func records() async -> AsyncStream<AutomationRunRecord>
}

/// Implemented by Task 13's `LiveTranscriptionWiring`.
public protocol LiveTranscriptPort: Sendable {
    func updates() async -> AsyncStream<[Utterance]>
}

public protocol OutputFolderPort: Sendable {
    func isAvailable() async -> Bool
}

public protocol FileOpener: Sendable {
    func open(_ file: URL) async
}

public struct AppPorts: Sendable {
    public var recorder: any RecorderPort
    public var events: any RecordingEventsPort
    public var queue: any QueuePort
    public var meetings: any MeetingsPort
    public var automations: any AutomationsPort
    public var live: any LiveTranscriptPort
    public var outputFolder: any OutputFolderPort
    public var opener: any FileOpener

    public init(recorder: any RecorderPort, events: any RecordingEventsPort, queue: any QueuePort, meetings: any MeetingsPort,
                automations: any AutomationsPort, live: any LiveTranscriptPort, outputFolder: any OutputFolderPort,
                opener: any FileOpener) {
        self.recorder = recorder
        self.events = events
        self.queue = queue
        self.meetings = meetings
        self.automations = automations
        self.live = live
        self.outputFolder = outputFolder
        self.opener = opener
    }
}
