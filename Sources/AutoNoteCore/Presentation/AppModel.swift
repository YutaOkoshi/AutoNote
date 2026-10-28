import Foundation
import Observation

public enum UserAction: Equatable, Sendable {
    case start, stop, pause, resume, bookmark(String?), cancelCountdown, setLanguage(Language), regenerate(MeetingID)
    case delete(MeetingID), rerunAutomation(name: String, meetingID: MeetingID), importAudio(URL, startedAt: Date?)
    case openLatestMinutes, open(MeetingID), notice(UserNoticeAction), toggleRecording, togglePause
    case redetectClaude, redetectClaudeAndRerun(MeetingID), retryModelDownload, installGuide
}

/// Everything the menu bar and the window show, gathered from the app's ports.
@MainActor @Observable public final class AppModel {
    /// The green band after a recording stops: which meeting and how long it was.
    public struct StoppedBand: Equatable, Sendable {
        public var id: MeetingID
        public var seconds: Int
        public init(id: MeetingID, seconds: Int) { self.id = id; self.seconds = seconds }
    }

    /// Minutes that were just written for the selected meeting, and where.
    public struct JustSaved: Equatable, Sendable {
        public var id: MeetingID
        public var path: String
        public init(id: MeetingID, path: String) { self.id = id; self.path = path }
    }

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
    public var selectedMeetingID: MeetingID? {
        didSet { if let j = justSaved, j.id != selectedMeetingID { justSaved = nil } }
    }
    /// Output folder and Claude Code from `ReadinessPort.current()`; the model from `ReadinessPort.updates()`.
    public private(set) var readiness: Readiness = .assumedReady
    /// The app sets these at launch and whenever the settings are saved; `menuBar(now:)` shows them.
    public var shortcuts = Shortcuts()
    /// The recording meter; nil unless recording, paused or in the grace period with a meeting.
    public private(set) var inputLevel: InputLevel?
    /// Meetings recorded in this launch whose minutes may still auto-select in the window. Regenerating, rerunning
    /// or importing never adds one, so those never move the selection.
    public private(set) var recordedThisSession: Set<MeetingID> = []
    public private(set) var stoppedBand: StoppedBand?
    public private(set) var justSaved: JustSaved?
    /// 「n 秒前に更新」 of the recording meeting's live summary, rebuilt on the 1-second tick; nil unless recording
    /// (or paused / in the grace period) with a result for that meeting.
    public private(set) var liveSummaryUpdatedText: String?
    /// The newest live summary update per meeting received in this launch.
    private var liveSummaries: [MeetingID: LiveSummaryUpdate] = [:]
    /// Withdraws the system notification of a prompt answered or resolved elsewhere (the app points it at
    /// `UserNotifier.withdraw(id:)`), so Notification Center keeps no stale buttons.
    /// True while the window's minutes editor holds unsaved edits (the app wires it to the editor). A stop does not
    /// move the selection away from them.
    @ObservationIgnored public var hasUnsavedEdits: @MainActor () -> Bool = { false }
    @ObservationIgnored public var withdrawNotice: (@MainActor (String) async -> Void)?

    @ObservationIgnored private let ports: AppPorts
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private var queueKey: [String] = []
    /// For `settle()`: streams subscribed so far and stream elements applied so far.
    @ObservationIgnored private var subscribed = 0
    @ObservationIgnored private var applied = 0
    @ObservationIgnored private var levelTracker = InputLevelTracker()
    @ObservationIgnored private let bandDuration: Duration

    private static let streamCount = 7
    private static let refreshInterval: Duration = .seconds(30)
    private static let tickInterval: Duration = .seconds(1)

    public init(ports: AppPorts, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current,
                bandDuration: Duration = .seconds(5)) {
        self.ports = ports
        self.now = now
        self.timeZone = timeZone
        self.bandDuration = bandDuration
    }

    /// Subscribes to every port until the calling task is cancelled.
    public func run() async {
        for record in await ports.automations.recentRuns(limit: 20).reversed() { apply(record) }
        recorder = await ports.recorder.current()
        await updateElapsed()
        queue = await ports.queue.status()
        queueKey = Self.key(queue)
        syncOverwritePrompts()
        readiness = await ports.readiness.current()
        await refreshRows()

        let ports = ports
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.consume(await ports.recorder.snapshots()) { await self.apply($0) } }
            group.addTask { await self.consume(await ports.events.events()) { await self.apply($0) } }
            group.addTask { await self.consume(await ports.queue.updates()) { await self.apply($0) } }
            group.addTask { await self.consume(await ports.live.updates()) { await self.applyLive($0) } }
            group.addTask { await self.consume(await ports.automations.records()) { await self.apply($0) } }
            group.addTask { await self.consume(await ports.readiness.updates()) { await self.applyModel($0) } }
            group.addTask { await self.consume(await ports.liveSummary.updates()) { await self.applyLiveSummary($0) } }
            group.addTask { await self.every(Self.refreshInterval) { await self.refresh() } }
            group.addTask { await self.every(Self.tickInterval) { await self.updateElapsed() } }
        }
    }

    /// Re-reads the output folder, Claude Code and the meeting list. The model keeps following `updates()`.
    public func refresh() async {
        let fresh = await ports.readiness.current()
        readiness = Readiness(outputFolder: fresh.outputFolder, model: readiness.model, claude: fresh.claude)
        await refreshRows()
    }

    private func refreshRows() async {
        syncOverwritePrompts()
        outputFolderAvailable = await ports.outputFolder.isAvailable()
        await reloadMeetings()
    }

    private func reloadMeetings() async {
        do {
            meetings = try await ports.meetings.rows()
            meetingsChanged()
        } catch {
            lastError = CommandRouter.ipcError(error).message
        }
    }

    /// Minutes for `id` are written. Selects it in the open window only for a meeting recorded in this launch, once,
    /// and never away from a selected meeting whose minutes the user may be editing. Never opens a window.
    /// - Returns: whether the selection moved to `id`.
    @discardableResult public func minutesReady(_ id: MeetingID, path: String?, windowOpen: Bool) -> Bool {
        let recorded = recordedThisSession.remove(id) != nil
        guard recorded, windowOpen else { return false }
        let selectedState = selectedMeetingID.flatMap { sel in meetings.first { $0.id == sel.rawValue }?.state }
        guard selectedMeetingID == nil || selectedMeetingID == id || selectedState != .minutesGenerated else { return false }
        selectedMeetingID = id
        justSaved = path.map { JustSaved(id: id, path: $0) }
        return true
    }

    /// The window's readiness bands, without what the selected meeting's failure band already says (plan 07 GUI #4).
    public func readinessBands(home: String) -> [ReadinessRow] {
        ReadinessPresentation.bands(readiness, home: home, failure: selectedFailure)
    }

    /// The failure band the selected meeting shows (`FailureBand`), or nil.
    private var selectedFailure: FailureExplanation? {
        guard let id = selectedMeetingID?.rawValue, let row = meetings.first(where: { $0.id == id }),
              let source = FailureExplanation.source(row: row, item: FailureExplanation.queueItem(for: id, in: queue.items))
        else { return nil }
        return FailureExplanation.make(source, outputFolderPath: readiness.outputFolder.path)
    }

    public func menuBar(now: Date) -> MenuBarPresentation {
        MenuBarPresentation.make(recorder: recorder, elapsedSeconds: elapsedSeconds, queue: queue,
                                 readiness: readiness,
                                 latestMinutesAvailable: meetings.contains { $0.filePath != nil }, rows: meetings,
                                 automationFailures: automationFailures, shortcuts: shortcuts, now: now, timeZone: timeZone)
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

    /// The newest live summary update of `id` received in this launch (the post-stop views fall back to the file).
    public func liveSummary(for id: MeetingID) -> LiveSummaryUpdate? { liveSummaries[id] }

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
        case .redetectClaude:
            readiness.claude = await ports.readiness.redetectClaude()
        case .redetectClaudeAndRerun(let id):
            readiness.claude = await ports.readiness.redetectClaude()
            guard readiness.claude.found else { throw AppCommandError.notFound("Claude Code（claude）が見つかりません") }
            try await ports.queue.retry(id)
        case .retryModelDownload: await ports.readiness.retryModelDownload()
        case .installGuide: await ports.readiness.installGuide()
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

    /// Too-short prompts follow the rows the same way: every `.tooShort` row has a prompt, and a prompt whose row is
    /// gone or no longer too short is dropped (and its notification withdrawn).
    private func syncTooShortPrompts() {
        let tooShort = meetings.filter { $0.state == .tooShort }.map { MeetingID(rawValue: $0.id) }
        let tooShortIDs = Set(tooShort.map { UserNotice.recordingTooShort($0).id })
        var stale: [String] = []
        prompts.removeAll { p in
            guard case .recordingTooShort = p, !tooShortIDs.contains(p.id) else { return false }
            stale.append(p.id)
            return true
        }
        for id in tooShort where !prompts.contains(where: { $0.id == UserNotice.recordingTooShort(id).id }) {
            prompts.append(.recordingTooShort(id))
        }
        if let withdraw = withdrawNotice {
            for id in stale { Task { await withdraw(id) } }
        }
    }

    /// After every `meetings` update: too-short prompts, and a failed or transcript-only meeting no longer auto-selects.
    private func meetingsChanged() {
        syncTooShortPrompts()
        let ended = Set(meetings.filter { $0.state == .failed || $0.state == .transcriptOnly }.map(\.id))
        recordedThisSession = recordedThisSession.filter { !ended.contains($0.rawValue) }
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
        guard [.recording, .paused, .grace].contains(s.state), let meetingID = s.meetingID else {
            elapsedSeconds = nil
            inputLevel = nil
            liveSummaryUpdatedText = nil
            return
        }
        updateLiveSummaryAge(meetingID)
        let levels = await ports.recorder.levels()
        inputLevel = levelTracker.observe(levels, recording: recorder.state == .recording)
        if let t = await ports.recorder.elapsed() {
            elapsedSeconds = max(0, Int(t.seconds))
        } else {
            elapsedSeconds = s.startedAt.map { max(0, Int(now().timeIntervalSince($0))) }
        }
    }

    private func apply(_ e: RecordingEvent) async {
        switch e {
        case .started(let id):
            live.reset()
            diskWarning = nil
            levelTracker = InputLevelTracker()
            recordedThisSession.insert(id)
            await refresh()
        case .diskSpaceLow:
            diskWarning = "ディスクの空きが 1GB を切りました"
        case .stopped(let m, let reason):
            if reason == .diskFull { diskWarning = "ディスクの空きが 500MB を切ったため録音を停止しました" }
            showStoppedBand(m)
            await refresh()
        default:
            break
        }
    }

    /// Shows the band for `bandDuration`, and selects the stopped meeting even when another one is selected (GUI #8),
    /// unless the open editor has unsaved edits. A too-short or failed recording gets no band: its own band (作る /
    /// 削除, or the failure) already says what happened, and the green one vanishing above it would shift its buttons.
    private func showStoppedBand(_ m: Manifest) {
        if selectedMeetingID == nil || !hasUnsavedEdits() { selectedMeetingID = m.id }
        guard m.status != .tooShort, m.status != .failed else {
            stoppedBand = nil
            return
        }
        let band = StoppedBand(id: m.id, seconds: Int(m.duration ?? 0))
        stoppedBand = band
        let duration = bandDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.stoppedBand?.id == band.id else { return }
            self.stoppedBand = nil
        }
    }

    private func applyModel(_ model: Readiness.Model) { readiness.model = model }

    private func apply(_ status: QueueStatus) async {
        queue = status
        syncOverwritePrompts()
        let key = Self.key(status)
        guard key != queueKey else { return }
        queueKey = key
        await reloadMeetings()
    }

    private func applyLive(_ snapshot: [Utterance]) { live.update(snapshot) }

    /// Kept per meeting: a late update of an earlier meeting never reaches the recording one's age line.
    private func applyLiveSummary(_ u: LiveSummaryUpdate) {
        liveSummaries[u.meetingID] = u
        let s = recorder
        guard [.recording, .paused, .grace].contains(s.state), let id = s.meetingID else {
            liveSummaryUpdatedText = nil
            return
        }
        updateLiveSummaryAge(id)
    }

    private func updateLiveSummaryAge(_ id: MeetingID) {
        liveSummaryUpdatedText = liveSummaries[id]?.state?.updatedAt.map {
            LiveSummaryPresentation.updatedText(updatedAt: $0, now: now())
        }
    }

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
