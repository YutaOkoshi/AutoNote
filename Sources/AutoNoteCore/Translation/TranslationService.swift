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
    /// Rewrites the meeting's Vault note once the minutes' translation changed (spec 2026-11-19 表示). An edited
    /// note is left alone (the writer's `.ifUnchanged` rule).
    public var rewriteNote: @Sendable (MeetingID) async -> Void

    public init(settings: @Sendable @escaping () async -> Settings, saveShown: @Sendable @escaping (Bool) async -> Void,
                store: TranslationStore, runtime: TranslationRuntime, runtimeAvailable: Bool,
                installedModel: @Sendable @escaping (TranslationModel) async -> URL?, profile: MachineProfile,
                now: @Sendable @escaping () -> Date = { Date() },
                rewriteNote: @Sendable @escaping (MeetingID) async -> Void = { _ in }) {
        self.settings = settings
        self.saveShown = saveShown
        self.store = store
        self.runtime = runtime
        self.runtimeAvailable = runtimeAvailable
        self.installedModel = installedModel
        self.profile = profile
        self.now = now
        self.rewriteNote = rewriteNote
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
    /// `minutes.json` (by modification date) already translated in this launch.
    private var summariesAttempted: [MeetingID: Date] = [:]
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

    /// The summaries' translations only in the current setting's direction (review L3).
    public func meetingTranslation(_ id: MeetingID) async -> MeetingTranslation {
        let setting = await deps.settings().translationTarget
        let live = deps.store.liveSummary(id).flatMap {
            SummaryTranslation.current(deps.store.loadSummary(id, .live), texts: SummaryTranslation.liveTexts($0),
                                       setting: setting)
        }
        let minutes = deps.store.minutes(id).flatMap {
            SummaryTranslation.current(deps.store.loadSummary(id, .minutes), texts: SummaryTranslation.minutesTexts($0),
                                       setting: setting)
        }
        return MeetingTranslation.make(document: deps.store.load(id), transcript: deps.store.finalTranscript(id),
                                       live: deps.store.loadLive(id), liveSummary: live, minutes: minutes)
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
                await startSummariesIfDue(MeetingID(rawValue: raw))
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

    /// Minutes made (or made again) after the transcript's translation — the usual order, since the summary comes
    /// after the final transcript — are translated once per `minutes.json` modification, if the mode asks for it.
    /// A running job of the meeting translates them itself when it gets there.
    func startSummariesIfDue(_ id: MeetingID) async {
        guard jobs[id] == nil, let modified = Self.modificationDate(deps.store.paths.minutesFile(id)),
              modified >= startedAt, summariesAttempted[id] != modified else { return }
        let s = await deps.settings()
        guard TranslationModelPolicy.effectiveMode(s.translationMode, profile: deps.profile).translatesAfterRecording,
              case .success = await deps.resolve(s) else { return }
        start(id, automatic: true, summariesOnly: true)
    }

    /// Whether `minutes.json` exists with a modification the summaries' translation has not started from.
    private func minutesChangedSinceAttempt(_ id: MeetingID) -> Bool {
        guard let modified = Self.modificationDate(deps.store.paths.minutesFile(id)) else { return false }
        return summariesAttempted[id] != modified
    }

    /// Minutes edited and saved in the app (`MeetingsAdapter.saveMinutes`, which bypasses the queue): their changed
    /// items are translated as for regenerated minutes (review L2).
    public func minutesSaved(_ id: MeetingID) async {
        await startSummariesIfDue(id)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Jobs

    /// Starts the meeting's job unless one runs. The task is not a child of the caller.
    func start(_ id: MeetingID, automatic: Bool, summariesOnly: Bool = false) {
        guard jobs[id] == nil else { return }
        publish(id, .queued)
        jobs[id] = Task(priority: .utility) { [weak self] in
            await self?.runJob(id, automatic: automatic, summariesOnly: summariesOnly)
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

    private func runJob(_ id: MeetingID, automatic: Bool, summariesOnly: Bool) async {
        defer { jobs[id] = nil }
        do {
            if !summariesOnly { try await translateMeeting(id, automatic: automatic) }
            // Then the summaries (spec 2026-11-19: 文字起こしに続けて議事録も訳す).
            // 「訳し直す」 redoes the summaries too, like the transcript (review M2).
            try await translateSummaries(id, fresh: !automatic)
            // Minutes written (or redone) while this job ran: `startSummariesIfDue` skipped them because the job was
            // running, and the meeting may have left the queue meanwhile, so the job takes them before it ends.
            while minutesChangedSinceAttempt(id) { try await translateSummaries(id) }
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
            await waitWhilePaused(id, TranslationProgress(done: document.processed, total: document.total))
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

    // MARK: - Summaries (spec 2026-11-19)

    /// The minutes' and the live summary's texts still to translate, each saved after every text; the Vault note is
    /// rewritten when the minutes' translation changed. Paused like the transcript's translation.
    /// `fresh` (a manual run) starts the stored translations over; so does a translation by another model or revision.
    private func translateSummaries(_ id: MeetingID, fresh: Bool = false) async throws {
        if let modified = Self.modificationDate(deps.store.paths.minutesFile(id)) { summariesAttempted[id] = modified }
        let s = await deps.settings()
        let current = try? await deps.resolve(s).get().0
        var work: [SummaryWork] = []
        if let m = deps.store.minutes(id) {
            work += summaryWork(id, .minutes, SummaryTranslation.minutesTexts(m), SummaryTranslation.minutesContext(m), s,
                                model: current, fresh: fresh)
        }
        if let l = deps.store.liveSummary(id) {
            work += summaryWork(id, .live, SummaryTranslation.liveTexts(l), SummaryTranslation.liveContext(l), s,
                                model: current, fresh: fresh)
        }
        let total = work.reduce(0) { $0 + $1.pending }
        guard total > 0 else { return }
        let (model, url) = try await deps.resolve(s).get()
        for i in work.indices {
            work[i].document.model = model.name
            work[i].document.modelRevision = model.revision
            work[i].document.target = s.translationTarget
        }
        var done = 0
        while true {
            await waitWhilePaused(id, TranslationProgress(done: done, total: total))
            try Task.checkCancellation()
            publish(id, .running(TranslationProgress(done: done, total: total)))
            let start = work, startDone = done
            let (finished, after, afterDone) = try await deps.runtime.withModel(url) { translator in
                var current = start, count = startDone
                for i in current.indices {
                    let kind = current[i].kind
                    let ok = try await SummaryTranslation.run(&current[i].document, texts: current[i].texts,
                                                              context: current[i].context, target: current[i].target,
                                                              translator: translator) { document in
                        count += 1
                        return await self.summaryCheckpoint(id, kind, document, TranslationProgress(done: count, total: total))
                    }
                    if !ok { return (false, current, count) }
                }
                return (true, current, count)
            }
            work = after
            done = afterDone
            if finished { break }
        }
        let now = deps.now()
        for var w in work {
            w.document.updatedAt = now
            try deps.store.saveSummary(w.document, w.kind, for: id)
        }
        logger.notice("\(id.rawValue, privacy: .public): translated \(total, privacy: .public) summary texts")
        if work.contains(where: { $0.kind == .minutes }) { await deps.rewriteNote(id) }
    }

    private struct SummaryWork: Sendable {
        var kind: SummaryKind
        var texts: [String]
        var context: [String]
        var target: TranslationLanguage
        var document: SummaryTranslationDocument
        var pending: Int
    }

    /// One summary's work, or nothing when its target is its own language or every text is translated already.
    private func summaryWork(_ id: MeetingID, _ kind: SummaryKind, _ texts: [String], _ context: [String],
                             _ s: Settings, model: TranslationModel?, fresh: Bool) -> [SummaryWork] {
        guard let target = SummaryTranslation.targetLanguage(for: texts, setting: s.translationTarget) else { return [] }
        let empty = SummaryTranslationDocument(model: "", modelRevision: "", target: s.translationTarget, updatedAt: deps.now())
        var document = deps.store.loadSummary(id, kind) ?? empty
        let otherModel = model.map { document.model != $0.name || document.modelRevision != $0.revision } ?? false
        if fresh || (otherModel && !document.entries.isEmpty) { document = empty }
        let pending = SummaryTranslation.pending(texts, target: target, document: document).count
        guard pending > 0 else { return [] }
        return [SummaryWork(kind: kind, texts: texts, context: context, target: target, document: document, pending: pending)]
    }

    private func summaryCheckpoint(_ id: MeetingID, _ kind: SummaryKind, _ document: SummaryTranslationDocument,
                                   _ progress: TranslationProgress) -> TranscriptTranslation.Checkpoint {
        publish(id, .running(progress))
        do {
            try deps.store.saveSummary(document, kind, for: id)
        } catch {
            logger.error("\(id.rawValue, privacy: .public): \(kind.fileName, privacy: .public) not saved (\(String(describing: type(of: error)), privacy: .public))")
        }
        return pauseReason == nil ? .proceed : .suspend
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
    private func waitWhilePaused(_ id: MeetingID, _ p: TranslationProgress) async {
        while let reason = pauseReason, !Task.isCancelled {
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
