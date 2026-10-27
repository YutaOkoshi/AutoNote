import Foundation
import Observation

public enum UserAction: Equatable, Sendable {
    case start, stop, pause, resume, bookmark(String?), cancelCountdown, setLanguage(Language), regenerate(MeetingID)
    case delete(MeetingID), rerunAutomation(name: String, meetingID: MeetingID), importAudio(URL, startedAt: Date?)
    case openLatestMinutes, open(MeetingID), notice(UserNoticeAction), toggleRecording, togglePause
}

/// Everything the menu bar and the window show, gathered from the app's ports.
@MainActor @Observable public final class AppModel {
    public private(set) var recorder: RecorderSnapshot = .idle(language: .ja)
    /// From `RecorderPort.elapsed()` (ruling X25), falling back to `now - startedAt`; nil when not recording.
    public private(set) var elapsedSeconds: Int?
    public private(set) var queue: QueueStatus = .empty
    public private(set) var meetings: [MeetingRow] = []
    public private(set) var live = LiveTranscriptBuffer()
    public private(set) var outputFolderAvailable = true
    public private(set) var automationFailures: [AutomationRunRecord] = []
    /// Notices that need an answer in the window's band: too short, interrupted, overwrite.
    public private(set) var prompts: [UserNotice] = []
    public private(set) var diskWarning: String?
    public private(set) var lastError: String?
    public var selectedMeetingID: MeetingID?
    /// Withdraws the system notification of a prompt answered or resolved elsewhere (the app points it at
    /// `UserNotifier.withdraw(id:)`), so Notification Center keeps no stale buttons.
    @ObservationIgnored public var withdrawNotice: (@MainActor (String) async -> Void)?

    @ObservationIgnored private let ports: AppPorts
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private var queueKey: [String] = []
    /// For `settle()`: streams subscribed so far and stream elements applied so far.
    @ObservationIgnored private var subscribed = 0
    @ObservationIgnored private var applied = 0

    private static let streamCount = 5
    private static let refreshInterval: Duration = .seconds(30)
    private static let tickInterval: Duration = .seconds(1)

    public init(ports: AppPorts, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.ports = ports
        self.now = now
        self.timeZone = timeZone
    }

    /// Subscribes to every port until the calling task is cancelled.
    public func run() async {
        for record in await ports.automations.recentRuns(limit: 20).reversed() { apply(record) }
        recorder = await ports.recorder.current()
        await updateElapsed()
        queue = await ports.queue.status()
        queueKey = Self.key(queue)
        syncOverwritePrompts()
        await refresh()

        let ports = ports
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.consume(await ports.recorder.snapshots()) { await self.apply($0) } }
            group.addTask { await self.consume(await ports.events.events()) { await self.apply($0) } }
            group.addTask { await self.consume(await ports.queue.updates()) { await self.apply($0) } }
            group.addTask { await self.consume(await ports.live.updates()) { await self.applyLive($0) } }
            group.addTask { await self.consume(await ports.automations.records()) { await self.apply($0) } }
            group.addTask { await self.every(Self.refreshInterval) { await self.refresh() } }
            group.addTask { await self.every(Self.tickInterval) { await self.updateElapsed() } }
        }
    }

    /// Re-reads the output folder and the meeting list.
    public func refresh() async {
        syncOverwritePrompts()
        outputFolderAvailable = await ports.outputFolder.isAvailable()
        do {
            meetings = try await ports.meetings.rows()
        } catch {
            lastError = CommandRouter.ipcError(error).message
        }
    }

    public func menuBar(now: Date) -> MenuBarPresentation {
        MenuBarPresentation.make(recorder: recorder, elapsedSeconds: elapsedSeconds, queue: queue,
                                 outputFolderAvailable: outputFolderAvailable,
                                 latestMinutesAvailable: meetings.contains { $0.filePath != nil }, rows: meetings,
                                 automationFailures: automationFailures, now: now, timeZone: timeZone)
    }

    public func perform(_ a: UserAction) async {
        do {
            try await execute(a)
            lastError = nil
        } catch {
            lastError = CommandRouter.ipcError(error).message
        }
    }

    public func noticePosted(_ n: UserNotice) {
        switch n {
        case .recordingTooShort, .interruptedRecordingFound, .overwriteConfirmation:
            if !prompts.contains(where: { $0.id == n.id }) { prompts.append(n) }
        default:
            break
        }
    }

    public func noticeWithdrawn(id: String) { prompts.removeAll { $0.id == id } }

    public func quitDecision(reason: QuitReason) -> QuitDecision { QuitPolicy.decide(recorder.state, reason: reason) }

    /// Test hook: waits (up to about 2 s each) until `run()` has subscribed to every stream and then until no
    /// stream element arrived for a few rounds.
    func settle() async {
        for _ in 0..<400 where subscribed < Self.streamCount {
            try? await Task.sleep(for: .milliseconds(5))
        }
        var quiet = 0
        var last = applied
        for _ in 0..<400 where quiet < 4 {
            try? await Task.sleep(for: .milliseconds(5))
            if applied == last { quiet += 1 } else { quiet = 0; last = applied }
        }
    }

    // MARK: - Actions

    private func execute(_ a: UserAction) async throws {
        let r = ports.recorder
        switch a {
        case .start: try await r.start(language: nil)
        case .stop: try await r.stop()
        case .pause: try await r.pause()
        case .resume: try await r.resume()
        case .bookmark(let note): _ = try await r.bookmark(note: note)
        case .cancelCountdown: await r.cancelCountdown()
        case .setLanguage(let l): await r.setLanguage(l)
        case .regenerate(let id): try await ports.queue.regenerate(id)
        case .delete(let id): try await ports.queue.delete(id)
        case .rerunAutomation(let name, let id): apply(try await ports.automations.run(name: name, meetingID: id))
        case .importAudio(let file, let startedAt):
            selectedMeetingID = try await ports.meetings.importAudio(file, startedAt: startedAt)
            await refresh()
        case .openLatestMinutes:
            guard let file = try await ports.meetings.latestMinutesFile() else { throw AppCommandError.notFound("議事録がまだありません") }
            await ports.opener.open(file)
        case .open(let id): selectedMeetingID = id
        case .notice(let action): try await handle(action)
        case .toggleRecording:
            // A manual start from the countdown discards it (§5.9); the grace period stops (ruling X34).
            switch recorder.state {
            case .idle, .countdown: try await r.start(language: nil)
            case .recording, .paused, .grace: try await r.stop()
            }
        case .togglePause:
            switch recorder.state {
            case .recording: try await r.pause()
            case .paused: try await r.resume()
            case .idle, .countdown, .grace: break
            }
        }
    }

    private func handle(_ action: UserNoticeAction) async throws {
        switch action {
        case .cancelCountdown, .startNow, .registerDevice:
            await ports.recorder.handleNotice(action)
        case .openMeeting(let id):
            selectedMeetingID = id
        case .retry(let id):
            try await ports.queue.retry(id)
        case .resolveOverwrite(let id, let overwrite):
            try await ports.queue.resolveOverwrite(id, overwrite: overwrite)
            await resolved(UserNotice.overwriteConfirmation(id).id)
        case .transcribeTooShort(let id):
            try await ports.queue.acceptShortRecording(id)
            await resolved(UserNotice.recordingTooShort(id).id)
        case .discardTooShort(let id):
            try await ports.queue.delete(id)
            await resolved(UserNotice.recordingTooShort(id).id)
        case .recoverInterrupted(let id):
            try await ports.meetings.recover(id)
            await resolved(UserNotice.interruptedRecordingFound(id).id)
        case .discardInterrupted(let id):
            try await ports.meetings.discard(id)
            await resolved(UserNotice.interruptedRecordingFound(id).id)
        case .openPrivacySettings:
            break   // The app opens System Settings itself.
        }
    }

    /// The prompt is answered: drop it from the band and withdraw its system notification (M8).
    private func resolved(_ id: String) async {
        noticeWithdrawn(id: id)
        await withdrawNotice?(id)
    }

    /// Overwrite prompts follow the queue state, not only posted notices, so a relaunch or a denied notification
    /// still shows the band (I1): every job awaiting confirmation has a prompt, and a prompt whose job no longer
    /// waits is dropped (and its notification withdrawn).
    private func syncOverwritePrompts() {
        let awaiting = queue.items.filter(\.awaitingConfirmation).map { MeetingID(rawValue: $0.meetingID) }
        let awaitingIDs = Set(awaiting.map { UserNotice.overwriteConfirmation($0).id })
        var stale: [String] = []
        prompts.removeAll { p in
            guard case .overwriteConfirmation = p, !awaitingIDs.contains(p.id) else { return false }
            stale.append(p.id)
            return true
        }
        for id in awaiting where !prompts.contains(where: { $0.id == UserNotice.overwriteConfirmation(id).id }) {
            prompts.append(.overwriteConfirmation(id))
        }
        if let withdraw = withdrawNotice {
            for id in stale { Task { await withdraw(id) } }
        }
    }

    // MARK: - Streams

    private func consume<Element: Sendable>(_ stream: AsyncStream<Element>, _ body: @Sendable (Element) async -> Void) async {
        subscribed += 1
        for await element in stream {
            await body(element)
            applied += 1
        }
    }

    private nonisolated func every(_ interval: Duration, _ body: @Sendable () async -> Void) async {
        while true {
            do { try await Task.sleep(for: interval) } catch { return }
            await body()
        }
    }

    private func apply(_ s: RecorderSnapshot) async {
        recorder = s
        await updateElapsed()
    }

    private func updateElapsed() async {
        let s = recorder
        guard [.recording, .paused, .grace].contains(s.state), s.meetingID != nil else {
            elapsedSeconds = nil
            return
        }
        if let t = await ports.recorder.elapsed() {
            elapsedSeconds = max(0, Int(t.seconds))
        } else {
            elapsedSeconds = s.startedAt.map { max(0, Int(now().timeIntervalSince($0))) }
        }
    }

    private func apply(_ e: RecordingEvent) async {
        switch e {
        case .started:
            live.reset()
            diskWarning = nil
            await refresh()
        case .diskSpaceLow:
            diskWarning = "ディスクの空きが 1GB を切りました"
        case .stopped(_, let reason):
            if reason == .diskFull { diskWarning = "ディスクの空きが 500MB を切ったため録音を停止しました" }
            await refresh()
        default:
            break
        }
    }

    private func apply(_ status: QueueStatus) async {
        queue = status
        syncOverwritePrompts()
        let key = Self.key(status)
        guard key != queueKey else { return }
        queueKey = key
        do {
            meetings = try await ports.meetings.rows()
        } catch {
            lastError = CommandRouter.ipcError(error).message
        }
    }

    private func applyLive(_ snapshot: [Utterance]) { live.update(snapshot) }

    /// A failed run is kept (one per name and meeting) until the same automation succeeds for that meeting.
    /// Skips (`already_ran`) change nothing.
    private func apply(_ record: AutomationRunRecord) {
        guard record.skippedReason == nil else { return }
        automationFailures.removeAll { $0.name == record.name && $0.meetingID == record.meetingID }
        if !record.succeeded { automationFailures.append(record) }
    }

    /// Rows change only with these fields, not with progress (ruling X20).
    private static func key(_ status: QueueStatus) -> [String] {
        status.items.map { "\($0.meetingID)\u{1F}\($0.state)\u{1F}\($0.stage)\u{1F}\($0.awaitingConfirmation)" }.sorted()
    }
}
