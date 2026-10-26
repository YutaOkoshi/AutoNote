import Foundation
import AutoNoteCore

/// Fan-out of values sent by a fake to every stream handed out so far (each `stream()` call subscribes once).
private struct Subscribers<Element: Sendable>: Sendable {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    mutating func stream(initial: Element? = nil, onTerminate: @escaping @Sendable (UUID) -> Void) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        continuation.onTermination = { _ in onTerminate(id) }
        continuations[id] = continuation
        if let initial { continuation.yield(initial) }
        return stream
    }

    mutating func remove(_ id: UUID) { continuations[id] = nil }

    func yield(_ value: Element) { for c in continuations.values { c.yield(value) } }
}

// MARK: - Recorder

/// Applies `RecorderCommandRules` against the current snapshot like `CoordinatorRecorderPort`, and moves the
/// state on success (start → recording, stop → idle, pause → paused, resume → recording).
public actor FakeRecorderPort: RecorderPort {
    public private(set) var calls: [String] = []
    public private(set) var snapshot: RecorderSnapshot
    public var nextError: AppCommandError?
    public var elapsedValue: TimelineTime?
    private var subscribers = Subscribers<RecorderSnapshot>()

    public init(_ snapshot: RecorderSnapshot = .idle(language: .ja)) { self.snapshot = snapshot }

    public func send(_ s: RecorderSnapshot) {
        snapshot = s
        subscribers.yield(s)
    }

    public func setNextError(_ e: AppCommandError?) { nextError = e }
    public func setElapsed(_ t: TimelineTime?) { elapsedValue = t }

    public func current() -> RecorderSnapshot { snapshot }

    public func snapshots() -> AsyncStream<RecorderSnapshot> {
        subscribers.stream(initial: snapshot) { [weak self] id in Task { await self?.unsubscribe(id) } }
    }

    public func elapsed() -> TimelineTime? { elapsedValue }

    public func start(language: Language?) throws {
        try perform("start(\(language?.rawValue ?? "nil"))", .start)
        move(to: .recording)
    }

    public func stop() throws {
        try perform("stop", .stop)
        move(to: .idle)
    }

    public func pause() throws {
        try perform("pause", .pause)
        move(to: .paused)
    }

    public func resume() throws {
        try perform("resume", .resume)
        move(to: .recording)
    }

    public func bookmark(note: String?) throws -> Bookmark {
        try perform("bookmark(\(note ?? "nil"))", .bookmark)
        return Bookmark(at: elapsedValue ?? .zero, note: note)
    }

    public func cancelCountdown() { calls.append("cancelCountdown") }
    public func setLanguage(_ l: Language) { calls.append("setLanguage(\(l.rawValue))") }
    public func handleNotice(_ action: UserNoticeAction) { calls.append("handleNotice(\(action))") }

    private func perform(_ call: String, _ command: RecorderCommand) throws(AppCommandError) {
        calls.append(call)
        try throwNextError()
        try RecorderCommandRules.check(command, state: snapshot.state)
    }

    private func throwNextError() throws(AppCommandError) {
        if let e = nextError {
            nextError = nil
            throw e
        }
    }

    private func move(to state: RecorderState) {
        var s = snapshot
        s.state = state
        send(s)
    }

    private func unsubscribe(_ id: UUID) { subscribers.remove(id) }
}

public actor FakeRecordingEventsPort: RecordingEventsPort {
    public private(set) var calls: [String] = []
    public var nextError: AppCommandError?
    private var subscribers = Subscribers<RecordingEvent>()

    public init() {}

    public func send(_ event: RecordingEvent) { subscribers.yield(event) }

    public func events() -> AsyncStream<RecordingEvent> {
        calls.append("events")
        return subscribers.stream { [weak self] id in Task { await self?.unsubscribe(id) } }
    }

    private func unsubscribe(_ id: UUID) { subscribers.remove(id) }
}

// MARK: - Queue

public actor FakeQueuePort: QueuePort {
    public private(set) var calls: [String] = []
    public private(set) var current: QueueStatus
    public var nextError: AppCommandError?
    private var subscribers = Subscribers<QueueStatus>()

    public init(_ status: QueueStatus = .empty) { current = status }

    public func send(_ status: QueueStatus) {
        current = status
        subscribers.yield(status)
    }

    public func setNextError(_ e: AppCommandError?) { nextError = e }

    public func status() -> QueueStatus { current }

    public func updates() -> AsyncStream<QueueStatus> {
        subscribers.stream(initial: current) { [weak self] id in Task { await self?.unsubscribe(id) } }
    }

    public func retry(_ id: MeetingID) throws { try record("retry(\(id.rawValue))") }
    public func regenerate(_ id: MeetingID) throws { try record("regenerate(\(id.rawValue))") }
    public func resolveOverwrite(_ id: MeetingID, overwrite: Bool) throws { try record("resolveOverwrite(\(id.rawValue),\(overwrite))") }
    public func acceptShortRecording(_ id: MeetingID) throws { try record("acceptShortRecording(\(id.rawValue))") }
    public func delete(_ id: MeetingID) throws { try record("delete(\(id.rawValue))") }

    private func record(_ call: String) throws(AppCommandError) {
        calls.append(call)
        if let e = nextError {
            nextError = nil
            throw e
        }
    }

    private func unsubscribe(_ id: UUID) { subscribers.remove(id) }
}

// MARK: - Meetings

public actor FakeMeetingsPort: MeetingsPort {
    public private(set) var calls: [String] = []
    public var nextError: AppCommandError?
    public private(set) var meetingRows: [MeetingRow] = []
    public var manifests: [MeetingID: Manifest] = [:]
    public var minutesByID: [MeetingID: MinutesOutput] = [:]
    public var transcripts: [String: Transcript] = [:]
    public var saveOutcome: SaveMinutesOutcome?
    public var importedID = MeetingID(rawValue: "20261024-1400-0000")

    public init(rows: [MeetingRow] = []) { meetingRows = rows }

    /// The rows `rows()` returns from now on.
    public func send(_ rows: [MeetingRow]) { meetingRows = rows }

    public func setNextError(_ e: AppCommandError?) { nextError = e }
    public func setManifest(_ m: Manifest) { manifests[m.id] = m }
    public func setMinutes(_ m: MinutesOutput, for id: MeetingID) { minutesByID[id] = m }
    public func setTranscript(_ t: Transcript, for id: MeetingID, kind: TranscriptKind) { transcripts["\(id.rawValue)/\(kind.rawValue)"] = t }
    public func setSaveOutcome(_ o: SaveMinutesOutcome?) { saveOutcome = o }
    public func setImportedID(_ id: MeetingID) { importedID = id }

    public func rows() throws -> [MeetingRow] {
        try record("rows")
        return meetingRows
    }

    public func latestMinutesFile() throws -> URL? {
        try record("latestMinutesFile")
        return meetingRows.first { $0.filePath != nil }?.filePath.map { URL(filePath: $0) }
    }

    public func manifest(_ id: MeetingID) throws -> Manifest {
        try record("manifest(\(id.rawValue))")
        guard let m = manifests[id] else { throw AppCommandError.notFound("会議が見つかりません: \(id.rawValue)") }
        return m
    }

    public func minutes(_ id: MeetingID) throws -> MinutesOutput? {
        try record("minutes(\(id.rawValue))")
        return minutesByID[id]
    }

    public func transcript(_ id: MeetingID, kind: TranscriptKind) throws -> Transcript? {
        try record("transcript(\(id.rawValue),\(kind.rawValue))")
        return transcripts["\(id.rawValue)/\(kind.rawValue)"]
    }

    public func saveMinutes(_ id: MeetingID, _ m: MinutesOutput, renameFile: Bool, overwrite: Bool) throws -> SaveMinutesOutcome {
        try record("saveMinutes(\(id.rawValue),\(m.title),rename:\(renameFile),overwrite:\(overwrite))")
        minutesByID[id] = m
        return saveOutcome ?? .saved(URL(filePath: "/tmp/\(id.rawValue).md"))
    }

    public func importAudio(_ file: URL, startedAt: Date?) throws -> MeetingID {
        try record("importAudio(\(file.path))")
        return importedID
    }

    public func recover(_ id: MeetingID) throws { try record("recover(\(id.rawValue))") }
    public func discard(_ id: MeetingID) throws { try record("discard(\(id.rawValue))") }

    private func record(_ call: String) throws(AppCommandError) {
        calls.append(call)
        if let e = nextError {
            nextError = nil
            throw e
        }
    }
}

// MARK: - Automations

public actor FakeAutomationsPort: AutomationsPort {
    public private(set) var calls: [String] = []
    public var nextError: AppCommandError?
    public var summaryList: [AutomationSummary]
    public var warnings: [String]
    public private(set) var runs: [AutomationRunRecord] = []
    private var subscribers = Subscribers<AutomationRunRecord>()

    public init(summaries: [AutomationSummary] = [], warnings: [String] = []) {
        summaryList = summaries
        self.warnings = warnings
    }

    /// Records a run: it shows in `recentRuns` and is yielded on `records()`.
    public func send(_ record: AutomationRunRecord) {
        runs.insert(record, at: 0)
        subscribers.yield(record)
    }

    public func setNextError(_ e: AppCommandError?) { nextError = e }
    public func setSummaries(_ s: [AutomationSummary], warnings: [String] = []) { summaryList = s; self.warnings = warnings }

    public func summaries() -> ([AutomationSummary], warnings: [String]) {
        calls.append("summaries")
        return (summaryList, warnings: warnings)
    }

    public func run(name: String, meetingID: MeetingID) throws -> AutomationRunRecord {
        calls.append("run(\(name),\(meetingID.rawValue))")
        if let e = nextError {
            nextError = nil
            throw e
        }
        let record = AutomationRunRecord(name: name, event: summaryList.first { $0.name == name }?.on ?? .minutesGenerated,
                                         meetingID: meetingID.rawValue, startedAt: Samples.start, durationSeconds: 0,
                                         exitCode: 0, timedOut: false, skippedReason: nil, logDirectory: "", failureMessage: nil)
        send(record)
        return record
    }

    public func recentRuns(limit: Int) -> [AutomationRunRecord] {
        calls.append("recentRuns(\(limit))")
        return Array(runs.prefix(limit))
    }

    public func records() -> AsyncStream<AutomationRunRecord> {
        subscribers.stream { [weak self] id in Task { await self?.unsubscribe(id) } }
    }

    private func unsubscribe(_ id: UUID) { subscribers.remove(id) }
}

// MARK: - Live transcript, output folder, opener

public actor FakeLiveTranscriptPort: LiveTranscriptPort {
    public private(set) var calls: [String] = []
    public var nextError: AppCommandError?
    private var subscribers = Subscribers<[Utterance]>()

    public init() {}

    public func send(_ lines: [Utterance]) { subscribers.yield(lines) }

    public func updates() -> AsyncStream<[Utterance]> {
        calls.append("updates")
        return subscribers.stream { [weak self] id in Task { await self?.unsubscribe(id) } }
    }

    private func unsubscribe(_ id: UUID) { subscribers.remove(id) }
}

public actor FakeOutputFolderPort: OutputFolderPort {
    public private(set) var calls: [String] = []
    public var nextError: AppCommandError?
    public private(set) var available: Bool

    public init(available: Bool = true) { self.available = available }

    public func send(_ available: Bool) { self.available = available }

    public func isAvailable() -> Bool {
        calls.append("isAvailable")
        return available
    }
}

public actor FakeFileOpener: FileOpener {
    public private(set) var calls: [String] = []
    public var nextError: AppCommandError?
    public private(set) var opened: [URL] = []

    public init() {}

    public func open(_ file: URL) {
        calls.append("open(\(file.path))")
        opened.append(file)
    }
}

/// One set of fakes wired into `AppPorts`.
public struct FakePorts: Sendable {
    public let recorder: FakeRecorderPort
    public let events: FakeRecordingEventsPort
    public let queue: FakeQueuePort
    public let meetings: FakeMeetingsPort
    public let automations: FakeAutomationsPort
    public let live: FakeLiveTranscriptPort
    public let outputFolder: FakeOutputFolderPort
    public let opener: FakeFileOpener
    public var ports: AppPorts

    public init(recorder: FakeRecorderPort = FakeRecorderPort(), events: FakeRecordingEventsPort = FakeRecordingEventsPort(),
                queue: FakeQueuePort = FakeQueuePort(), meetings: FakeMeetingsPort = FakeMeetingsPort(),
                automations: FakeAutomationsPort = FakeAutomationsPort(), live: FakeLiveTranscriptPort = FakeLiveTranscriptPort(),
                outputFolder: FakeOutputFolderPort = FakeOutputFolderPort(), opener: FakeFileOpener = FakeFileOpener()) {
        self.recorder = recorder
        self.events = events
        self.queue = queue
        self.meetings = meetings
        self.automations = automations
        self.live = live
        self.outputFolder = outputFolder
        self.opener = opener
        ports = AppPorts(recorder: recorder, events: events, queue: queue, meetings: meetings, automations: automations,
                         live: live, outputFolder: outputFolder, opener: opener)
    }
}
