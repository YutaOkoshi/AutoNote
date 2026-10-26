import Foundation
import os
import Synchronization

public enum QueueError: Error, Equatable {
    case unknownMeeting(MeetingID)
    case unknownStage(String)
    case notTooShort(MeetingStatus)
}

/// The persistent post-processing queue (要件書 §8.1). Runs exactly one stage at a time across all jobs,
/// oldest runnable job first, and persists every state change through `JobStore`.
public actor PostProcessingQueue {
    /// A stage's `.retry(after:)` is honoured this many times; the next retry result fails the job.
    /// The hourly rate-limit rerun counts its rounds against the same limit.
    public static let maxAttempts = 24
    static let rateLimitDelay: TimeInterval = 3600
    static let lastErrorLimit = 300
    static let overwritePrefix = "overwrite_confirmation: "
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "PostProcessingQueue")

    struct RunningStage {
        var meeting: MeetingID
        var stage: String
        var token: Int
        var task: Task<Job, any Error>
    }

    private struct Subscribers {
        var latest = QueueSnapshot(jobs: [], pausedForRecording: false)
        var continuations: [UUID: AsyncStream<QueueSnapshot>.Continuation] = [:]
    }

    let paths: AppPaths
    let activity: any RecordingActivity
    let gate: BatchGate
    let clock: any QueueClock
    let jobStore: JobStore
    let manifests: ManifestStore
    let settingsStore: SettingsStore

    var stages: [String: any QueueStage] = [:]
    /// In-memory mirror of the saved jobs, keyed by `meeting.rawValue`.
    var jobs: [String: Job] = [:]
    var progress: [String: Double] = [:]
    var running: RunningStage?
    /// The step in flight (one at a time); cancelling it cancels the stage it runs.
    var stepTask: Task<Void, Never>?
    var loopTask: Task<Void, Never>?
    var loadTask: Task<Void, Never>?
    /// The latest `RecordingActivity` value. While `true`, no `transcribe` stage starts and `gate` is paused.
    var isRecording = false
    /// Feeds `activity.isRecordingUpdates()` into `setRecording(_:)` between `start()` and `stop()`.
    var recordingTask: Task<Void, Never>?
    /// Rate-limit rounds of a summarize rerun in flight (the waiting job keeps them in `attempts`).
    var rateLimitRounds: [String: Int] = [:]
    /// Meetings with a `rerun` in progress; no stage of theirs may start until the reset is saved.
    var rerunsInProgress: Set<String> = []
    private var runToken = 0
    private var stopping = false
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var wakePending = false
    private let subscribers = Mutex(Subscribers())

    public init(paths: AppPaths, stages: [any QueueStage], activity: any RecordingActivity, gate: BatchGate,
                clock: any QueueClock = SystemQueueClock()) {
        self.paths = paths
        self.activity = activity
        self.gate = gate
        self.clock = clock
        self.jobStore = JobStore(paths: paths)
        self.manifests = ManifestStore(paths: paths)
        self.settingsStore = SettingsStore(paths: paths)
        for stage in stages { self.stages[stage.name] = stage }
    }

    public func register(_ stage: any QueueStage) {
        stages[stage.name] = stage
    }

    // MARK: - Lifecycle

    /// Loads saved jobs (an interrupted `.running` job goes back to `.pending` without counting the attempt)
    /// and starts the loop.
    public func start() async {
        await ensureLoaded()
        if recordingTask == nil {
            let activity = self.activity
            recordingTask = Task {
                for await recording in await activity.isRecordingUpdates() {
                    if Task.isCancelled { break }
                    await self.setRecording(recording)
                }
            }
        }
        guard loopTask == nil else { return }
        loopTask = Task { await self.loop() }
    }

    /// Pauses (`true`) or resumes (`false`) the batch transcription. A running `transcribe` is not cancelled;
    /// it stops at the gate. Resuming wakes the loop so held `transcribe` stages start.
    func setRecording(_ recording: Bool) async {
        guard recording != isRecording else { return }
        isRecording = recording
        if recording {
            await gate.pause()
            Self.logger.info("recording started: final transcription paused")
        } else {
            await gate.resume()
            Self.logger.info("recording ended: final transcription resumed")
            wake()
        }
        publish()
    }

    /// Cancels the running stage (its job returns to `.pending`) and ends the loop.
    public func stop() async {
        stopping = true
        recordingTask?.cancel()
        recordingTask = nil
        loopTask?.cancel()
        stepTask?.cancel()
        wake()
        await loopTask?.value
        await stepTask?.value
        loopTask = nil
        stopping = false
    }

    /// Runs stages until no job is runnable now. Never sleeps.
    public func runUntilIdle() async {
        await ensureLoaded()
        while true {
            if let current = stepTask {
                await current.value
                continue
            }
            guard !stopping, !Task.isCancelled, let job = nextRunnable() else { return }
            let meeting = job.meeting
            let task = Task { await self.step(meeting) }
            stepTask = task
            await task.value
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            await runUntilIdle()
            if Task.isCancelled { break }
            await waitForWake(until: earliestNotBefore())
        }
    }

    private func waitForWake(until deadline: Date?) async {
        if wakePending {
            wakePending = false
            return
        }
        let sleeper = deadline.map { deadline in
            Task { [clock] in
                do {
                    try await clock.sleep(until: deadline)
                    self.wake()
                } catch {}
            }
        }
        await withCheckedContinuation { wakeContinuation = $0 }
        sleeper?.cancel()
    }

    func wake() {
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        } else {
            wakePending = true
        }
    }

    // MARK: - Commands

    /// Creates a job for a `.recorded` meeting. Anything else (existing job, unreadable manifest, other status)
    /// is logged and ignored.
    public func enqueue(_ id: MeetingID) async {
        await ensureLoaded()
        guard jobs[id.rawValue] == nil else { return }
        guard let manifest = try? await manifests.load(id) else {
            Self.logger.error("enqueue \(id.rawValue, privacy: .public): manifest unreadable")
            return
        }
        guard manifest.status == .recorded else {
            Self.logger.info("enqueue \(id.rawValue, privacy: .public): status \(manifest.status.rawValue, privacy: .public), skipped")
            return
        }
        guard jobs[id.rawValue] == nil else { return }
        let job = Job(id: id.rawValue, meeting: id, stages: StageName.all, completedStages: [], state: .pending,
                      attempts: 0, lastError: nil, notBefore: nil, createdAt: clock.now())
        await persist(job)
        Self.logger.info("enqueue \(id.rawValue, privacy: .public): pending")
        wake()
    }

    /// Re-runs the job from `stage`: later stages are cleared. From `summarize` or earlier bumps `generation`.
    public func rerun(_ id: MeetingID, from stage: String) async throws {
        guard StageName.all.contains(stage) else { throw QueueError.unknownStage(stage) }
        await ensureLoaded()
        guard jobs[id.rawValue] != nil else { throw QueueError.unknownMeeting(id) }
        // Hold the job first so the loop cannot start its next stage while we wait for the current one.
        rerunsInProgress.insert(id.rawValue)
        defer { rerunsInProgress.remove(id.rawValue) }
        while jobs[id.rawValue]?.state == .running, let current = stepTask {
            // The one step in flight is this job's; cancelling it puts the job back to `.pending`.
            current.cancel()
            await current.value
        }
        guard var job = jobs[id.rawValue] else { throw QueueError.unknownMeeting(id) }
        Self.resetForRerun(&job, from: stage)
        rateLimitRounds[id.rawValue] = nil
        await persist(job)
        Self.logger.info("rerun \(id.rawValue, privacy: .public) from \(stage, privacy: .public): generation \(job.generation)")
        wake()
    }

    /// Runs a failed (or time-waiting) job's next stage now. Anything else is logged and ignored.
    public func retry(_ id: MeetingID) async {
        await ensureLoaded()
        guard var job = jobs[id.rawValue],
              job.state == .failed || (job.state == .waiting && job.notBefore != nil) else {
            Self.logger.info("retry \(id.rawValue, privacy: .public): nothing to retry")
            return
        }
        job.state = .pending
        job.notBefore = nil
        job.attempts = 0
        await persist(job)
        Self.logger.info("retry \(id.rawValue, privacy: .public): pending")
        wake()
    }

    /// Answers an overwrite confirmation: `true` re-runs `write_vault` allowed to overwrite; `false` leaves
    /// the Vault alone and finishes the job. Only a job awaiting confirmation (`.waiting`, no `notBefore`)
    /// is touched; anything else (missing job, other state, e.g. a stale notification) is logged and ignored.
    public func resolveOverwrite(_ id: MeetingID, overwrite: Bool) async throws {
        await ensureLoaded()
        guard var job = jobs[id.rawValue], job.state == .waiting, job.notBefore == nil else {
            Self.logger.info("resolveOverwrite \(id.rawValue, privacy: .public): not awaiting confirmation, ignored")
            return
        }
        job.lastError = nil
        if overwrite {
            job.overwriteApproved = true
            job.state = .pending
            await persist(job)
            Self.logger.info("resolveOverwrite \(id.rawValue, privacy: .public): overwrite")
            wake()
        } else {
            // Manifest first: if it cannot be updated, the job stays awaiting confirmation.
            try await manifests.update(id) { $0.status = .minutesGenerated }
            for stage in [StageName.writeVault, StageName.updateIndex, StageName.automations]
            where !job.completedStages.contains(stage) {
                job.completedStages.append(stage)
            }
            job.attempts = 0
            job.state = .done
            await persist(job)
            Self.logger.info("resolveOverwrite \(id.rawValue, privacy: .public): keep, done")
        }
    }

    // MARK: - Snapshots

    public func snapshot() -> QueueSnapshot {
        let visible = jobs.values
            .filter { $0.state != .done || $0.summaryFailure != nil }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return QueueSnapshot(jobs: visible.map { job in
            let key = job.meeting.rawValue
            let stage = running.flatMap { $0.meeting == job.meeting ? $0.stage : nil } ?? job.nextStage
            return JobProgress(meetingID: job.meeting, stage: stage, state: job.state, progress: progress[key],
                               notBefore: job.notBefore, lastError: job.lastError,
                               summaryFailure: SummaryFailureKind.of(job.summaryFailure),
                               awaitingConfirmation: job.state == .waiting && job.notBefore == nil,
                               generation: job.generation)
        }, pausedForRecording: isRecording && jobs.values.contains(where: Self.waitsForTranscribe))
    }

    /// A fresh stream per call: the current snapshot first, then every change.
    public nonisolated func snapshots() -> AsyncStream<QueueSnapshot> {
        let (stream, continuation) = AsyncStream<QueueSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        subscribers.withLock { s in
            s.continuations[id] = continuation
            continuation.yield(s.latest)
        }
        return stream
    }

    private nonisolated func removeSubscriber(_ id: UUID) {
        _ = subscribers.withLock { $0.continuations.removeValue(forKey: id) }
    }

    func publish() {
        let current = snapshot()
        subscribers.withLock { s in
            guard s.latest != current else { return }
            s.latest = current
            for continuation in s.continuations.values { continuation.yield(current) }
        }
    }

    // MARK: - Internals

    func ensureLoaded() async {
        if loadTask == nil {
            loadTask = Task { await self.loadSavedJobs() }
        }
        await loadTask?.value
    }

    private func loadSavedJobs() async {
        let saved: [Job]
        do {
            saved = try await jobStore.all()
        } catch {
            Self.logger.error("could not list saved jobs")
            saved = []
        }
        for var job in saved where jobs[job.meeting.rawValue] == nil {
            if job.state == .running {
                job.state = .pending
                job.attempts = max(0, job.attempts - 1)
                await persist(job)
                Self.logger.info("resume \(job.meeting.rawValue, privacy: .public): interrupted stage back to pending")
            } else {
                jobs[job.meeting.rawValue] = job
            }
        }
        publish()
    }

    /// Updates the mirror, saves, then tells subscribers (so a snapshot never runs ahead of the disk).
    func persist(_ job: Job) async {
        jobs[job.meeting.rawValue] = job
        do {
            try await jobStore.save(job)
        } catch {
            Self.logger.error("could not save job \(job.meeting.rawValue, privacy: .public)")
        }
        publish()
    }

    /// A job that is still to (or now does) run `transcribe`, which a recording holds back.
    static func waitsForTranscribe(_ job: Job) -> Bool {
        guard job.nextStage == StageName.transcribe else { return false }
        switch job.state {
        case .pending, .waiting, .running: return true
        case .failed, .done: return false
        }
    }

    func isRunnable(_ job: Job, now: Date) -> Bool {
        if rerunsInProgress.contains(job.meeting.rawValue) { return false }
        if isRecording && job.nextStage == StageName.transcribe { return false }
        switch job.state {
        case .pending: return true
        case .waiting: return job.notBefore.map { $0 <= now } ?? false
        case .running, .failed, .done: return false
        }
    }

    func nextRunnable() -> Job? {
        let now = clock.now()
        return jobs.values
            .filter { isRunnable($0, now: now) }
            .min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    func earliestNotBefore() -> Date? {
        jobs.values.filter { $0.state == .waiting }.compactMap(\.notBefore).min()
    }

    static func resetForRerun(_ job: inout Job, from stage: String) {
        guard let index = StageName.all.firstIndex(of: stage) else { return }
        let kept = Set(StageName.all.prefix(index))
        job.completedStages = job.completedStages.filter { kept.contains($0) }
        job.state = .pending
        job.attempts = 0
        job.lastError = nil
        job.notBefore = nil
        job.overwriteApproved = false
        if let summarize = StageName.all.firstIndex(of: StageName.summarize), index <= summarize {
            job.generation += 1
            job.summaryFailure = nil
        }
    }

    private static func short(_ text: String) -> String { String(text.prefix(lastErrorLimit)) }

    /// Runs (at most) one stage of the job and records its outcome.
    private func step(_ id: MeetingID) async {
        await runStep(id)
        stepTask = nil
    }

    private func runStep(_ id: MeetingID) async {
        let key = id.rawValue
        let settings: Settings
        do {
            settings = try await settingsStore.load()
        } catch {
            Self.logger.error("job \(key, privacy: .public): settings unreadable, using defaults")
            settings = Settings()
        }
        guard var job = jobs[key], isRunnable(job, now: clock.now()) else { return }

        // A finished job picked again is a rate-limited one whose hour is up (or was retried).
        if job.nextStage == nil {
            let rounds = job.attempts
            Self.resetForRerun(&job, from: StageName.summarize)
            job.attempts = rounds
            rateLimitRounds[key] = rounds
            Self.logger.info("rerun \(key, privacy: .public) from summarize after rate limit, round \(rounds + 1)")
        }

        // Unregistered known stages are completed without running; unknown names fail the job.
        while let next = job.nextStage, stages[next] == nil {
            guard StageName.all.contains(next) else {
                job.state = .failed
                job.lastError = "unknown_stage: \(next)"
                await persist(job)
                Self.logger.error("job \(key, privacy: .public): unknown stage \(next, privacy: .public), failed")
                return
            }
            job.completedStages.append(next)
        }
        guard let stageName = job.nextStage, let stage = stages[stageName] else {
            finish(&job)
            await persist(job)
            return
        }

        job.state = .running
        job.attempts += 1
        job.notBefore = nil
        await persist(job)
        if Task.isCancelled {
            job.state = .pending
            job.attempts -= 1
            await persist(job)
            return
        }

        runToken += 1
        let token = runToken
        progress[key] = nil
        let clock = self.clock
        let context = StageContext(
            paths: paths, settings: settings, manifests: manifests,
            now: { clock.now() },
            reportProgress: { [weak self] value in
                Task { await self?.report(id, token: token, value) }
            })
        let input = job
        let task = Task.detached { () async throws -> Job in
            var working = input
            try await stage.run(&working, context: context)
            return working
        }
        running = RunningStage(meeting: id, stage: stageName, token: token, task: task)
        Self.logger.info("job \(key, privacy: .public) stage \(stageName, privacy: .public): running, attempt \(job.attempts)")
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        running = nil
        progress[key] = nil

        switch result {
        case .success(var done):
            if !done.completedStages.contains(stageName) { done.completedStages.append(stageName) }
            done.attempts = 0
            done.lastError = nil
            done.notBefore = nil
            done.state = .pending
            if done.nextStage == nil { finish(&done) }
            job = done
            Self.logger.info("job \(key, privacy: .public) stage \(stageName, privacy: .public): done, job \(job.state.rawValue, privacy: .public)")
        case .failure(let error as StageError):
            switch error {
            case .retry(let after, let reason):
                job.lastError = Self.short(reason)
                if job.attempts > Self.maxAttempts {
                    job.state = .failed
                    Self.logger.error("job \(key, privacy: .public) stage \(stageName, privacy: .public): retries exhausted, failed")
                } else {
                    job.state = .waiting
                    job.notBefore = clock.now().addingTimeInterval(after)
                    Self.logger.info("job \(key, privacy: .public) stage \(stageName, privacy: .public): waiting \(after, privacy: .public)s")
                }
            case .failed(let reason):
                job.state = .failed
                job.lastError = Self.short(reason)
                Self.logger.error("job \(key, privacy: .public) stage \(stageName, privacy: .public): failed")
            case .awaitingConfirmation(let path):
                job.state = .waiting
                job.notBefore = nil
                job.lastError = Self.short(Self.overwritePrefix + path)
                Self.logger.info("job \(key, privacy: .public) stage \(stageName, privacy: .public): awaiting overwrite confirmation")
            }
        case .failure(is CancellationError):
            job.state = .pending
            job.attempts = max(0, job.attempts - 1)
            Self.logger.info("job \(key, privacy: .public) stage \(stageName, privacy: .public): cancelled, pending")
        case .failure(let error):
            job.state = .failed
            job.lastError = Self.short(String(describing: error))
            Self.logger.error("job \(key, privacy: .public) stage \(stageName, privacy: .public): failed with \(String(describing: type(of: error)), privacy: .public)")
        }
        await persist(job)
    }

    /// All stages are complete: rate-limited summaries wait an hour for a summarize rerun, others are done.
    private func finish(_ job: inout Job) {
        let key = job.meeting.rawValue
        let carried = rateLimitRounds.removeValue(forKey: key) ?? 0
        guard SummaryFailureKind.of(job.summaryFailure) == .rateLimited else {
            job.state = .done
            return
        }
        let rounds = carried + 1
        if rounds > Self.maxAttempts {
            job.state = .failed
            job.attempts = rounds
            job.lastError = job.summaryFailure.map(Self.short)
            Self.logger.error("job \(key, privacy: .public): rate limit rounds exhausted, failed")
        } else {
            job.state = .waiting
            job.attempts = rounds
            job.notBefore = clock.now().addingTimeInterval(Self.rateLimitDelay)
            Self.logger.info("job \(key, privacy: .public): rate limited, summarize again in 1 hour")
        }
    }

    private func report(_ id: MeetingID, token: Int, _ value: Double) {
        guard let current = running, current.meeting == id, current.token == token else { return }
        progress[id.rawValue] = value
        publish()
    }
}
