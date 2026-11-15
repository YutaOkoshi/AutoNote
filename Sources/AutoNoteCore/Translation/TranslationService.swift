import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "TranslationService")

/// What the translation feature needs from the app. Shared by `TranslationService` and `LiveTranslator`.
public struct TranslationDependencies: Sendable {
    public var settings: @Sendable () async -> Settings
    /// Saves the 「訳文」 switch (a settings write of `translation_shown` only).
    public var saveShown: @Sendable (Bool) async -> Void
    public var store: TranslationStore
    public var runtime: TranslationRuntime
    /// False when the build has no on-device runtime (`TranslationRuntimeFactory.makeOnDevice()` gave nil).
    public var runtimeAvailable: Bool
    /// The downloaded file of `model`, nil when it is not installed.
    public var installedModel: @Sendable (TranslationModel) async -> URL?
    public var profile: MachineProfile
    public var now: @Sendable () -> Date

    public init(settings: @Sendable @escaping () async -> Settings, saveShown: @Sendable @escaping (Bool) async -> Void,
                store: TranslationStore, runtime: TranslationRuntime, runtimeAvailable: Bool,
                installedModel: @Sendable @escaping (TranslationModel) async -> URL?, profile: MachineProfile,
                now: @Sendable @escaping () -> Date = { Date() }) {
        self.settings = settings
        self.saveShown = saveShown
        self.store = store
        self.runtime = runtime
        self.runtimeAvailable = runtimeAvailable
        self.installedModel = installedModel
        self.profile = profile
        self.now = now
    }

    /// The model to use and its file, or why translation cannot run now (mode aside).
    func resolve(_ s: Settings) async -> Result<(TranslationModel, URL), TranslationError> {
        guard runtimeAvailable else { return .failure(.runtimeUnavailable) }
        guard TranslationLicense.isAccepted(s) else { return .failure(.licenseNotAccepted) }
        let model = TranslationModelPolicy.resolveModel(setting: s.translationModel, profile: profile)
        guard let url = await installedModel(model) else { return .failure(.modelNotInstalled(model.displayName)) }
        return .success((model, url))
    }
}

/// The post-recording translation (spec 6) and the port the window uses. A job runs beside the minutes pipeline,
/// never inside it: the queue is only observed, so translation neither waits for the minutes nor makes them wait,
/// and nothing here changes a manifest or a transcript. Jobs pause while a recording runs (the live side and the
/// live transcription come first) and while the queue makes a final transcript (Whisper's batch run must not share
/// the machine with the model), releasing the model, and continue after. The minutes (claude) do not pause them.
public actor TranslationService: TranslationPort {
    private let deps: TranslationDependencies
    private let broadcaster: TranslationBroadcaster
    private let startedAt: Date
    private var jobs: [MeetingID: Task<Void, Never>] = [:]
    private var states: [MeetingID: TranslationJobState] = [:]
    private var revisions: [MeetingID: Int] = [:]
    /// Final transcripts (by `final.json` modification date) already translated automatically in this launch.
    private var autoAttempted: [MeetingID: Date] = [:]
    private var recording = false
    /// A queue job is making a final transcript (stage `transcribe`, running or about to).
    private var transcribing = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    /// How many utterances between two saves of a running `translation.json`.
    static let saveEvery = 20

    public init(_ deps: TranslationDependencies, broadcaster: TranslationBroadcaster = TranslationBroadcaster()) {
        self.deps = deps
        self.broadcaster = broadcaster
        startedAt = deps.now()
    }

    // MARK: - Port

    public func updates() -> AsyncStream<TranslationUpdate> {
        broadcaster.subscribe(initial: states.map { .job($0.key, $0.value, revision: revisions[$0.key] ?? 0) })
    }

    public func meetingTranslation(_ id: MeetingID) -> MeetingTranslation {
        MeetingTranslation.make(document: deps.store.load(id), transcript: deps.store.finalTranscript(id),
                                live: deps.store.loadLive(id))
    }

    public func translate(_ id: MeetingID) async throws {
        guard deps.store.finalTranscript(id) != nil else {
            throw AppCommandError.invalid(TranslationError.noTranscript.message)
        }
        if case .failure(let e) = await deps.resolve(await deps.settings()) {
            throw AppCommandError.invalid(e.message)
        }
        start(id, automatic: false)
    }

    public func availability() async -> TranslationAvailability {
        switch await deps.resolve(await deps.settings()) {
        case .success: .ready
        case .failure(.runtimeUnavailable): .runtimeUnavailable
        case .failure(.licenseNotAccepted): .licenseNotAccepted
        case .failure:
            .modelNotInstalled(TranslationModelPolicy.resolveModel(setting: await deps.settings().translationModel,
                                                                   profile: deps.profile))
        }
    }

    public func setShown(_ shown: Bool) async { await deps.saveShown(shown) }

    // MARK: - Automatic start (spec 6)

    /// Follows the queue until the stream ends: once a meeting's job has moved past `transcribe` (or left the
    /// queue) with a final transcript written in this launch, that transcript is translated once, if the mode
    /// asks for it.
    public func follow(queue: AsyncStream<QueueStatus>) async {
        var tracked: Set<String> = []
        for await status in queue {
            setTranscribing(Self.isTranscribing(status))
            let items = Dictionary(status.items.map { ($0.meetingID, $0) }, uniquingKeysWith: { _, new in new })
            tracked.formUnion(items.keys)
            for raw in tracked {
                if let item = items[raw], item.stage == StageName.transcribe { continue }
                if items[raw] == nil { tracked.remove(raw) }
                await startAutomaticallyIfDue(MeetingID(rawValue: raw))
            }
        }
    }

    /// Follows the recording state: jobs pause while it is true.
    public func follow(recording updates: AsyncStream<Bool>) async {
        for await value in updates { setRecording(value) }
    }

    func setRecording(_ value: Bool) {
        guard recording != value else { return }
        recording = value
        wakePaused()   // parked jobs resume, or show the reason that is left
    }

    func setTranscribing(_ value: Bool) {
        guard transcribing != value else { return }
        transcribing = value
        wakePaused()
    }

    /// Whether the queue is making (or about to make) a final transcript: a job in `transcribe` that is running or
    /// pending. A job waiting for a retry or a confirmation does not hold translation back.
    static func isTranscribing(_ status: QueueStatus) -> Bool {
        status.items.contains {
            $0.stage == StageName.transcribe
                && ($0.state == JobState.running.rawValue || $0.state == JobState.pending.rawValue)
        }
    }

    /// Whether the queue was last seen making a final transcript (tests).
    var isTranscribing: Bool { transcribing }

    private enum PauseReason { case recording, transcription }

    private var pauseReason: PauseReason? {
        if recording { return .recording }
        if transcribing { return .transcription }
        return nil
    }

    func startAutomaticallyIfDue(_ id: MeetingID) async {
        guard jobs[id] == nil else { return }
        let finalURL = deps.store.paths.transcriptFile(id, .final)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: finalURL.path))?[.modificationDate] as? Date,
              modified >= startedAt, autoAttempted[id] != modified else { return }
        autoAttempted[id] = modified
        let s = await deps.settings()
        guard TranslationModelPolicy.effectiveMode(s.translationMode, profile: deps.profile).translatesAfterRecording else {
            return
        }
        if case .failure(let e) = await deps.resolve(s) {
            logger.notice("\(id.rawValue, privacy: .public): not translated after the recording (\(e.message, privacy: .public))")
            return
        }
        start(id, automatic: true)
    }

    // MARK: - Jobs

    /// Starts the meeting's job unless one runs. The task is not a child of the caller.
    func start(_ id: MeetingID, automatic: Bool) {
        guard jobs[id] == nil else { return }
        publish(id, .queued)
        jobs[id] = Task(priority: .utility) { [weak self] in
            await self?.runJob(id, automatic: automatic)
        }
    }

    /// Cancels every job and unloads the runtime (the app's quit path; spec 10).
    public func shutdown() async {
        let running = Array(jobs.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
        await deps.runtime.shutdown()
    }

    /// Waits for the running job of `id` (tests).
    func waitForJob(_ id: MeetingID) async {
        await jobs[id]?.value
    }

    func state(_ id: MeetingID) -> TranslationJobState? { states[id] }

    private func runJob(_ id: MeetingID, automatic: Bool) async {
        defer { jobs[id] = nil }
        do {
            try await translateMeeting(id, automatic: automatic)
            revisions[id, default: 0] += 1
            publish(id, nil)
        } catch is CancellationError {
            logger.notice("\(id.rawValue, privacy: .public): translation cancelled")
            publish(id, nil)
        } catch {
            let message = (error as? TranslationError)?.message ?? String(describing: error)
            logger.error("\(id.rawValue, privacy: .public): translation failed (\(message, privacy: .public))")
            publish(id, .failed("翻訳できませんでした（\(message)）"))
        }
    }

    private func translateMeeting(_ id: MeetingID, automatic: Bool) async throws {
        let s = await deps.settings()
        let (model, url) = try await deps.resolve(s).get()
        guard let transcript = deps.store.finalTranscript(id) else { throw TranslationError.noTranscript }
        let digest = TranslationKey.digest(transcript.utterances)
        let plan = TranscriptTranslation.plan(transcript.utterances, target: s.translationTarget)
        let existing = deps.store.load(id)
        var document: TranslationDocument
        if let existing, existing.sourceDigest == digest, existing.target == s.translationTarget,
           existing.model == model.name, existing.modelRevision == model.revision {
            if existing.complete, automatic { return }
            document = existing.complete ? Self.fresh(model, s, digest, plan.count, deps.now()) : existing
        } else {
            document = Self.fresh(model, s, digest, plan.count, deps.now())
        }
        try deps.store.save(document, for: id)

        while true {
            await waitWhilePaused(id, document)
            try Task.checkCancellation()
            publish(id, .running(TranslationProgress(done: document.processed, total: document.total)))
            let start = document
            let utterances = transcript.utterances
            let (finished, after) = try await deps.runtime.withModel(url) { translator in
                var d = start
                do {
                    let finished = try await TranscriptTranslation.run(&d, utterances: utterances, plan: plan,
                                                                       translator: translator) { current in
                        await self.checkpoint(id, current)
                    }
                    return (finished, d)
                } catch {
                    await self.saveQuietly(d, id)
                    throw error
                }
            }
            document = after
            if finished { break }
            try deps.store.save(document, for: id)
        }
        try deps.store.save(document, for: id)
        // The final translation replaces what was translated while recording (spec 7, 8).
        deps.store.deleteLive(id)
        logger.notice("\(id.rawValue, privacy: .public): translated \(document.entries.count, privacy: .public) of \(document.total, privacy: .public) utterances")
    }

    private static func fresh(_ model: TranslationModel, _ s: Settings, _ digest: String, _ total: Int,
                              _ now: Date) -> TranslationDocument {
        TranslationDocument(model: model.name, modelRevision: model.revision, target: s.translationTarget,
                            createdAt: now, sourceDigest: digest, total: total, complete: false, entries: [])
    }

    /// After each utterance: progress, a save every `saveEvery`, and a pause when a recording or a final
    /// transcription started.
    private func checkpoint(_ id: MeetingID, _ document: TranslationDocument) -> TranscriptTranslation.Checkpoint {
        publish(id, .running(TranslationProgress(done: document.processed, total: document.total)))
        if document.processed % Self.saveEvery == 0 { saveQuietly(document, id) }
        return pauseReason == nil ? .proceed : .suspend
    }

    private func saveQuietly(_ document: TranslationDocument, _ id: MeetingID) {
        do {
            try deps.store.save(document, for: id)
        } catch {
            logger.error("\(id.rawValue, privacy: .public): translation.json not saved (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    /// Parks the job (the model released) while a recording or a final transcription runs; the state says which.
    private func waitWhilePaused(_ id: MeetingID, _ document: TranslationDocument) async {
        while let reason = pauseReason, !Task.isCancelled {
            let p = TranslationProgress(done: document.processed, total: document.total)
            publish(id, reason == .recording ? .waitingForRecording(p) : .waitingForTranscription(p))
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in
                    if pauseReason != nil && !Task.isCancelled { pauseWaiters.append(c) } else { c.resume() }
                }
            } onCancel: {
                Task { await self.wakePaused() }
            }
        }
    }

    /// Wakes every parked job; each checks `pauseReason` again (a cancelled job must not stay parked either).
    private func wakePaused() {
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    private func publish(_ id: MeetingID, _ state: TranslationJobState?) {
        states[id] = state
        broadcaster.send(.job(id, state, revision: revisions[id] ?? 0))
    }
}
