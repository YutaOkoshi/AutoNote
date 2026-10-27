import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "LiveAdapters")

extension AppCommandError {
    /// `AppCommandError` passes through; anything else from plans 01–05 becomes `.failed(localizedDescription)`.
    static func wrap(_ error: any Error) -> AppCommandError {
        if let e = error as? AppCommandError { return e }
        return .failed(error.localizedDescription)
    }

    static let outputFolderMissing = AppCommandError.failed("保存先が見つかりません")

    static func meetingNotFound(_ id: MeetingID) -> AppCommandError { .notFound("会議が見つかりません: \(id.rawValue)") }
}

private func wrapping<T>(_ body: () async throws -> T) async throws(AppCommandError) -> T {
    do { return try await body() } catch { throw AppCommandError.wrap(error) }
}

private func wrappingSync<T>(_ body: () throws -> T) throws(AppCommandError) -> T {
    do { return try body() } catch { throw AppCommandError.wrap(error) }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

/// Maps a stream element by element; cancelling the result stops reading the source.
private func mapped<A: Sendable, B: Sendable>(_ source: AsyncStream<A>, _ transform: @escaping @Sendable (A) -> B) -> AsyncStream<B> {
    AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
        let task = Task {
            for await value in source { continuation.yield(transform(value)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Recorder

public struct CoordinatorRecorderPort: RecorderPort {
    private let coordinator: AutoRecordCoordinator
    private let elapsedTime: @Sendable () async -> TimelineTime?
    private let currentLevels: @Sendable () async -> [TrackLevel]

    /// `elapsed` is wired to `RecordingSession.elapsed()` by Task 13 (ruling X25); `levels` to `RecordingSession.levels()`.
    public init(coordinator: AutoRecordCoordinator, elapsed: @escaping @Sendable () async -> TimelineTime? = { nil },
                levels: @escaping @Sendable () async -> [TrackLevel] = { [] }) {
        self.coordinator = coordinator
        self.elapsedTime = elapsed
        self.currentLevels = levels
    }

    public func current() async -> RecorderSnapshot { await coordinator.current() }
    public func snapshots() async -> AsyncStream<RecorderSnapshot> { await coordinator.snapshots() }
    public func elapsed() async -> TimelineTime? { await elapsedTime() }
    public func levels() async -> [TrackLevel] { await currentLevels() }

    public func start(language: Language?) async throws {
        try await check(.start)
        try await wrapping { try await coordinator.manualStart(language: language) }
    }

    public func stop() async throws {
        try await check(.stop)
        await coordinator.stop()
    }

    public func pause() async throws {
        try await check(.pause)
        await coordinator.pause()
    }

    public func resume() async throws {
        try await check(.resume)
        await coordinator.resume()
    }

    public func bookmark(note: String?) async throws -> Bookmark {
        try await check(.bookmark)
        do {
            return try await coordinator.bookmark(note: note)
        } catch AutoRecordError.notRecording {
            throw AppCommandError.notRecording
        } catch {
            throw AppCommandError.wrap(error)
        }
    }

    public func cancelCountdown() async { await coordinator.cancelCountdown() }
    public func setLanguage(_ l: Language) async { await coordinator.setLanguage(l) }
    public func handleNotice(_ action: UserNoticeAction) async { await coordinator.handle(action) }

    private func check(_ c: RecorderCommand) async throws(AppCommandError) {
        try RecorderCommandRules.check(c, state: await coordinator.current().state)
    }
}

public struct SessionEventsPort: RecordingEventsPort {
    private let session: RecordingSession

    public init(session: RecordingSession) { self.session = session }

    public func events() async -> AsyncStream<RecordingEvent> { await session.events() }
}

// MARK: - Queue

/// Reads the queue through `holder` on every call, so a replaced queue is never held on to.
public struct QueueAdapter: QueuePort {
    private let holder: QueueHolder

    public init(holder: QueueHolder) { self.holder = holder }

    public func status() async -> QueueStatus { Self.status(await holder.queue.snapshot()) }

    public func updates() async -> AsyncStream<QueueStatus> {
        mapped(await holder.queue.snapshots(), Self.status)
    }

    /// Rulings X14/X14b: a failed or time-waiting job resumes where it stopped (`retry`); a job that finished
    /// with a summary failure regenerates (`regenerate`, generation + 1). Without a job (e.g. after a restart
    /// dropped a finished job) a finished meeting regenerates; an in-flight or too-short one is refused.
    public func retry(_ id: MeetingID) async throws {
        let queue = await holder.queue
        try requireManifest(id, queue)
        if let job = await queue.snapshot().jobs.first(where: { $0.meetingID == id }) {
            switch job.state {
            case .failed:
                return await queue.retry(id)
            case .waiting where job.notBefore != nil:
                return await queue.retry(id)
            case .waiting where job.awaitingConfirmation:
                throw AppCommandError.invalid("上書きの確認待ちです: \(id.rawValue)")
            case .done where job.summaryFailure != nil:
                return try await regenerate(id, on: queue)
            case .pending, .running, .waiting:
                throw AppCommandError.invalid("処理中です: \(id.rawValue)")
            case .done:
                break  // not in snapshots in practice; treat like no job
            }
        }
        let manifest = try wrappingSync {
            try AutoNoteJSON.decoder().decode(Manifest.self, from: Data(contentsOf: queue.paths.manifestFile(id)))
        }
        switch manifest.status {
        case .transcriptOnly, .failed, .minutesGenerated:
            try await regenerate(id, on: queue)
        case .recording, .recorded, .transcribing, .transcribed, .generating:
            throw AppCommandError.invalid("処理中です: \(id.rawValue)")
        case .tooShort:
            throw AppCommandError.invalid("短すぎる録音です: \(id.rawValue)")
        }
    }

    public func regenerate(_ id: MeetingID) async throws {
        let queue = await holder.queue
        try requireManifest(id, queue)
        try await regenerate(id, on: queue)
    }

    public func resolveOverwrite(_ id: MeetingID, overwrite: Bool) async throws {
        let queue = await holder.queue
        try requireManifest(id, queue)
        try await mappingQueueErrors(id) { try await queue.resolveOverwrite(id, overwrite: overwrite) }
    }

    public func acceptShortRecording(_ id: MeetingID) async throws {
        let queue = await holder.queue
        try requireManifest(id, queue)
        try await mappingQueueErrors(id) { try await queue.acceptShortRecording(id) }
    }

    public func delete(_ id: MeetingID) async throws {
        let queue = await holder.queue
        try requireManifest(id, queue)
        do {
            try await queue.delete(id)
        } catch RetentionError.outputFolderUnavailable {
            throw AppCommandError.outputFolderMissing
        } catch {
            throw AppCommandError.wrap(error)
        }
    }

    // MARK: Helpers

    private func regenerate(_ id: MeetingID, on queue: PostProcessingQueue) async throws {
        guard exists(queue.paths.transcriptFile(id, .final)) else {
            throw AppCommandError.invalid("文字起こしがありません: \(id.rawValue)")
        }
        await queue.regenerate(id)
    }

    private func requireManifest(_ id: MeetingID, _ queue: PostProcessingQueue) throws(AppCommandError) {
        guard exists(queue.paths.manifestFile(id)) else { throw .meetingNotFound(id) }
    }

    /// Ruling X13b.
    private func mappingQueueErrors(_ id: MeetingID, _ body: () async throws -> Void) async throws(AppCommandError) {
        do {
            try await body()
        } catch QueueError.notTooShort {
            throw .invalid("短すぎる録音ではありません: \(id.rawValue)")
        } catch let error as QueueError {
            throw .invalid("\(id.rawValue): \(String(describing: error))")
        } catch {
            throw .wrap(error)
        }
    }

    /// Every job, including done jobs with a `summaryFailure` (ruling X15). Nil stage → `""` with no label.
    static func status(_ snapshot: QueueSnapshot) -> QueueStatus {
        QueueStatus(items: snapshot.jobs.map { job in
            QueueItemDTO(meetingID: job.meetingID.rawValue, stage: job.stage ?? "", state: job.state.rawValue,
                         progress: job.progress, label: job.stage.map { StageLabel.text(stage: $0, progress: job.progress) } ?? "",
                         message: job.lastError, awaitingConfirmation: job.awaitingConfirmation,
                         summaryFailure: job.summaryFailure?.rawValue, generation: job.generation, notBefore: job.notBefore)
        }, pausedForRecording: snapshot.pausedForRecording)
    }
}

// MARK: - Meetings

public struct MeetingsAdapter: MeetingsPort {
    private let paths: AppPaths
    private let manifests: ManifestStore
    private let settings: SettingsStore
    private let output: OutputFolderServices
    private let importer: AudioImporter
    private let crashRecovery: CrashRecovery
    private let route: @Sendable (Manifest) async -> Void
    private let appVersion: String
    private let queueStatus: @Sendable () async -> QueueStatus
    private let timeZone: TimeZone

    /// `route` is Task 13's `AppWiring.route` (enqueue, or the too-short notice). `queueStatus` feeds the
    /// rows' processing labels (wire it to `QueuePort.status`).
    public init(paths: AppPaths, manifests: ManifestStore, settings: SettingsStore, output: OutputFolderServices,
                importer: AudioImporter, crashRecovery: CrashRecovery, route: @escaping @Sendable (Manifest) async -> Void,
                appVersion: String = AutoNoteVersion.current,
                queueStatus: @escaping @Sendable () async -> QueueStatus = { .empty }, timeZone: TimeZone = .current) {
        self.paths = paths
        self.manifests = manifests
        self.settings = settings
        self.output = output
        self.importer = importer
        self.crashRecovery = crashRecovery
        self.route = route
        self.appVersion = appVersion
        self.queueStatus = queueStatus
        self.timeZone = timeZone
    }

    public func rows() async throws -> [MeetingRow] {
        let vault = await output.vault()
        var index: [IndexEntry] = []
        if let vault, isDirectory(vault.folder) {
            index = try wrappingSync { try VaultScanner.scan(outputFolder: vault.folder) }
        }
        return MeetingListBuilder.build(index: index, manifests: await manifests.all(), queue: await queueStatus(),
                                        outputFolder: vault?.folder, timeZone: timeZone)
    }

    public func latestMinutesFile() async throws -> URL? {
        try await rows().first { $0.filePath != nil }?.filePath.map { URL(filePath: $0) }
    }

    public func manifest(_ id: MeetingID) async throws -> Manifest {
        guard exists(paths.manifestFile(id)) else { throw AppCommandError.meetingNotFound(id) }
        return try await wrapping { try await manifests.load(id) }
    }

    public func minutes(_ id: MeetingID) async throws -> MinutesOutput? {
        try read(MinutesOutput.self, at: paths.minutesFile(id))
    }

    public func transcript(_ id: MeetingID, kind: TranscriptKind) async throws -> Transcript? {
        try read(Transcript.self, at: paths.transcriptFile(id, kind))
    }

    /// `minutes.json` → manifest title → Vault file (overview order). When the Vault file was edited outside,
    /// `minutes.json` keeps the new minutes and the Vault is left alone until the next save or regeneration.
    public func saveMinutes(_ id: MeetingID, _ m: MinutesOutput, renameFile: Bool, overwrite: Bool) async throws -> SaveMinutesOutcome {
        var updated = try await manifest(id)
        guard let vault = await output.vault(), isDirectory(vault.folder) else { throw AppCommandError.outputFolderMissing }
        guard let final = try read(Transcript.self, at: paths.transcriptFile(id, .final)) else {
            throw AppCommandError.invalid("文字起こしがありません: \(id.rawValue)")
        }
        let title = m.title
        updated.title = title

        // The Vault first: `minutes.json` and the manifest title change only once the note was written (M5), so a
        // declined overwrite leaves nothing for a later `write_vault` to publish.
        let outcome: VaultWriteOutcome
        do {
            let text = try await output.portable().read(.frontmatter).map { String(decoding: $0, as: UTF8.self) }
                ?? FrontmatterTemplate.defaultText
            let document = MeetingDocument(manifest: updated, transcript: final, minutes: m,
                                           frontmatter: FrontmatterTemplate(text: text), appVersion: appVersion, timeZone: timeZone)
            outcome = try await vault.writer.write(document, policy: overwrite ? .force : .ifUnchanged, renameToMatchTitle: renameFile)
        } catch VaultError.outputFolderUnavailable {
            throw AppCommandError.outputFolderMissing
        } catch {
            throw AppCommandError.wrap(error)
        }
        switch outcome {
        case .written(let url):
            let minutesURL = paths.minutesFile(id)
            try wrappingSync {
                try FileManager.default.createDirectory(at: minutesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AutoNoteJSON.encoder().encode(m).write(to: minutesURL, options: .atomic)
            }
            _ = try await wrapping { try await manifests.update(id) { $0.title = title } }
            // The note is saved; a stale index is fixed by the next write, so its failure is only logged.
            do { _ = try await vault.writer.rebuildIndex() } catch {
                logger.error("\(id.rawValue, privacy: .public): index rebuild failed (\(String(describing: type(of: error)), privacy: .public))")
            }
            return .saved(url)
        case .conflict(let url): return .externallyEdited(url)
        }
    }

    public func importAudio(_ file: URL, startedAt: Date?) async throws -> MeetingID {
        let language = (try? await settings.load())?.defaultLanguage ?? Settings().defaultLanguage
        let manifest = try await wrapping { try await importer.importFile(file, startedAt: startedAt, language: language) }
        await route(manifest)
        return manifest.id
    }

    public func recover(_ id: MeetingID) async throws {
        _ = try await manifest(id)
        let manifest = try await wrapping { try await crashRecovery.recover(id) }
        await route(manifest)
    }

    public func discard(_ id: MeetingID) async throws {
        _ = try await manifest(id)
        try await wrapping { try await crashRecovery.discard(id) }
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard exists(url) else { return nil }
        return try wrappingSync { try AutoNoteJSON.decoder().decode(type, from: Data(contentsOf: url)) }
    }
}

// MARK: - Automations

public struct AutomationsAdapter: AutomationsPort {
    private let file: AutomationsFile
    private let dispatcher: AutomationDispatcher
    private let runner: AutomationRunner
    private let manifests: ManifestStore
    private let paths: AppPaths
    private let output: OutputFolderServices

    public init(file: AutomationsFile, dispatcher: AutomationDispatcher, runner: AutomationRunner, manifests: ManifestStore,
                paths: AppPaths, output: OutputFolderServices) {
        self.file = file
        self.dispatcher = dispatcher
        self.runner = runner
        self.manifests = manifests
        self.paths = paths
        self.output = output
    }

    public func summaries() async -> ([AutomationSummary], warnings: [String]) {
        let loaded = file.load()
        let list = loaded.items.map {
            AutomationSummary(name: $0.definition.name, on: $0.definition.on, enabled: $0.definition.enabled,
                              isRunnable: $0.isRunnable, problem: $0.problem)
        }
        return (list, warnings: loaded.warnings)
    }

    /// Runs `name` for `meetingID` with the context its trigger would carry; the dispatcher decides
    /// whether it exists and is runnable.
    public func run(name: String, meetingID: MeetingID) async throws -> AutomationRunRecord {
        let loaded = file.load()
        let event = loaded.items.first { $0.definition.name == name }?.definition.on ?? .minutesGenerated
        guard exists(paths.manifestFile(meetingID)) else { throw AppCommandError.meetingNotFound(meetingID) }
        let manifest = try await wrapping { try await manifests.load(meetingID) }
        let minutesURL = paths.minutesFile(meetingID)
        var noteFile: URL?
        if let vault = await output.vault(), let record = await vault.writer.record(for: meetingID) {
            noteFile = vault.folder.appending(path: record.relativePath)
        }
        let context = AutomationContextBuilder.make(event: event, manifest: manifest, file: noteFile,
                                                    minutesJSON: exists(minutesURL) ? minutesURL : nil)
        return try await dispatcher.runOne(name: name, context: context, loaded: loaded)
    }

    public func recentRuns(limit: Int) async -> [AutomationRunRecord] { await runner.recentRuns(limit: limit) }

    public func records() async -> AsyncStream<AutomationRunRecord> { await runner.records() }
}

// MARK: - Output folder

public struct PortableOutputFolderPort: OutputFolderPort {
    private let output: OutputFolderServices

    public init(output: OutputFolderServices) { self.output = output }

    public func isAvailable() async -> Bool { await output.portable().isOutputAvailable }
}
