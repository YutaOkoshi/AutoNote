import Foundation
import os

/// One live recording at a time: two sources → per-track segmented WAV writers, with the manifest kept current.
///
/// Public operations run one at a time (`OperationGate`), so a long `start` or `stop` never interleaves with a
/// `pause` or `bookmark`. Audio does not go through the gate: the sources yield into a `ChunkQueue` and one consumer
/// task handles chunks in arrival order (silence monitor → writer → `audio(for:)` subscriber).
public actor RecordingSession {
    public struct Configuration: Sendable, Equatable {
        public var language: Language
        public var microphoneUID: String?     // nil = 既定入力（手動開始、要件書 §5.1）
        public var device: DeviceRef?         // 起点機材。nil なら sources.inputDevice(uid: microphoneUID)

        public init(language: Language, microphoneUID: String? = nil, device: DeviceRef? = nil) {
            self.language = language; self.microphoneUID = microphoneUID; self.device = device
        }
    }

    public static let minimumDurationSeconds: Double = 60

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "RecordingSession")

    let paths: AppPaths
    let manifests: ManifestStore
    nonisolated let sources: any AudioSourceFactory
    let host: any HostClock
    let disk: any DiskSpaceProvider
    let now: @Sendable () -> Date
    let tickInterval: Duration
    let timeZone: TimeZone

    public private(set) var state: SessionState = .idle
    private let broadcaster = EventBroadcaster<RecordingEvent>()
    var audioSubscribers: [Track: (id: UUID, continuation: AsyncStream<AudioChunk>.Continuation)] = [:]

    // Per meeting; set by `start`, cleared by `stop` or a failed start.
    private var meetingID: MeetingID?
    private var clock: MeetingClock?
    private var startedAt = Date(timeIntervalSince1970: 0)
    var writers = TrackWriters()
    var monitor: SilenceMonitor?
    private var silenceWarning = false
    var stats: [Track: TrackStatistics] = [:]
    private var micSource: (any AudioSource)?
    private var systemSource: (any AudioSource)?
    private var ticker: Task<Void, Never>?

    // Chunk pipeline (RecordingSession+Pipeline.swift; internal rather than private for that file).
    var queue: ChunkQueue?
    var consumer: Task<Void, Never>?
    var processed = 0
    var idleWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private var saver: ManifestSaver?
    private var gate = OperationGate()

    public init(paths: AppPaths, manifests: ManifestStore, sources: any AudioSourceFactory,
                host: any HostClock = MachHostClock(), disk: any DiskSpaceProvider = SystemDiskSpace(),
                now: @escaping @Sendable () -> Date = { Date() }, tickInterval: Duration = .seconds(1),
                timeZone: TimeZone = .current) {
        self.paths = paths; self.manifests = manifests; self.sources = sources; self.host = host; self.disk = disk
        self.now = now; self.tickInterval = tickInterval; self.timeZone = timeZone
    }

    /// アプリ用の組み立て（計画 03・06 の `AppEnvironment.make` が使う）。
    public static func live(paths: AppPaths, settings: Settings, clock: any HostClock = MachHostClock()) -> RecordingSession {
        RecordingSession(paths: paths, manifests: ManifestStore(paths: paths),
                         sources: LiveAudioSourceFactory(voiceProcessing: settings.voiceProcessing),
                         host: clock, disk: SystemDiskSpace())
    }

    // MARK: - Queries

    /// A new subscription each call; every subscriber gets the same events from now on. Streams live as long as the
    /// app (they span meetings); only cancelling one removes it.
    public func events() -> AsyncStream<RecordingEvent> { broadcaster.subscribe() }

    var subscriberCount: Int { broadcaster.count }

    public func elapsed() -> TimelineTime {
        guard state != .idle, let clock else { return .zero }
        return clock.now()
    }

    /// Live chunks of `track` for real-time transcription. Not fed while paused; finished at `stop`.
    /// Calling again finishes the previous stream.
    public func audio(for track: Track) -> AsyncStream<AudioChunk> {
        audioSubscribers[track]?.continuation.finish()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { await self?.removeAudioSubscriber(track, id) } }
        audioSubscribers[track] = (id, continuation)
        return stream
    }

    private func removeAudioSubscriber(_ track: Track, _ id: UUID) {
        if audioSubscribers[track]?.id == id { audioSubscribers[track] = nil }
    }

    public func statistics() -> [Track: TrackStatistics] { stats }

    // MARK: - Operations

    public func start(_ configuration: Configuration) async throws -> MeetingID {
        try await serialized { try await performStart(configuration) }
    }

    public func pause() async throws {
        try await serialized {
            let (id, clock) = try active()
            guard case .recording = state else { throw RecordingError.alreadyPaused }
            let at = clock.now()
            await waitUntilIdle()                       // chunks that arrived before the pause are still written
            state = .paused(id)
            let (changes, failures) = writers.transition { try $0.close(at: at) }
            try await persist { $0.pauses.append(PauseInterval(start: at)); $0.apply(changes) }
            broadcaster.yield(.paused(at))
            await reportWriterFailures(failures)
        }
    }

    public func resume() async throws {
        try await serialized {
            let (id, clock) = try active()
            guard case .paused = state else { throw RecordingError.notPaused }
            let at = clock.now()
            let (changes, failures) = writers.transition(skippingFailed: true) { try $0.open(at: at) }
            state = .recording(id)
            try await persist { m in
                if let i = m.pauses.lastIndex(where: { $0.end == nil }) { m.pauses[i].end = at }
                m.apply(changes)
            }
            broadcaster.yield(.resumed(at))
            // The recording goes on with the tracks that opened; the caller still learns that resume was incomplete.
            await reportWriterFailures(failures)
            if let (_, error) = failures.first { throw error }
        }
    }

    @discardableResult
    public func bookmark(note: String? = nil) async throws -> Bookmark {
        try await serialized {
            _ = try active()
            let bookmark = Bookmark(at: elapsed(), note: note)
            try await persist { $0.bookmarks.append(bookmark) }
            broadcaster.yield(.bookmarked(bookmark))
            return bookmark
        }
    }

    public func setLanguage(_ language: Language) async throws {
        try await serialized {
            _ = try active()
            try await persist { $0.language = language }
        }
    }

    /// 起点機材の切断。マイクの writer は開いたままにし、続きは次のチャンクか停止時の `close(at:)` が無音で埋める。
    public func detachMicrophone() async throws {
        try await serialized {
            _ = try active()
            guard let mic = micSource else { return }
            let at = elapsed()
            micSource = nil
            await mic.stop()
            broadcaster.yield(.microphoneDetached(at))
        }
    }

    /// 機材の復帰。失敗したら音源のエラーをそのまま throw する（呼び手は nil = 既定入力で呼び直す）。
    public func attachMicrophone(deviceUID: String?) async throws {
        try await serialized {
            let (_, clock) = try active()
            guard let queue else { throw RecordingError.notRecording }
            if let old = micSource {
                micSource = nil
                await old.stop()
            }
            let mic = sources.makeMicrophoneSource(deviceUID: deviceUID, clock: clock)
            try await mic.start(onBuffer: queue.onBuffer(for: .mic))
            micSource = mic
            broadcaster.yield(.microphoneAttached(elapsed(), device: sources.inputDevice(uid: deviceUID)))
        }
    }

    public func stop(reason: StopReason = .manual) async throws -> Manifest {
        try await serialized { try await performStop(reason: reason) }
    }

    // MARK: - Test hooks

    /// Periodic work while recording (silence warnings; Task 11 adds disk checks).
    ///
    /// Rule: `tick()` never calls `stop` inline (it runs inside the ticker task, which `stop` cancels). When a tick must
    /// end the recording it spawns `Task { try? await self.stop(reason: …) }` and returns.
    func tick() async {
        guard state != .idle, var monitor else { return }
        let paused = if case .paused = state { true } else { false }
        let warnings = monitor.tick(now: elapsed(), paused: paused)
        self.monitor = monitor
        for warning in warnings { broadcaster.yield(.silenceWarning(warning)) }
        if !warnings.isEmpty, !silenceWarning {
            silenceWarning = true
            do { try await persist { $0.silenceWarning = true } } catch { Self.log("silence flag save", error) }
        }
    }

    // MARK: - Start / stop

    private func performStart(_ configuration: Configuration) async throws -> MeetingID {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        let startedAt = now()
        let id = MeetingID.make(start: startedAt, timeZone: timeZone)
        let clock = MeetingClock(origin: host.hostTime(), host: host)
        let device = configuration.device ?? sources.inputDevice(uid: configuration.microphoneUID)
        let initial = Manifest(
            id: id, title: nil, startedAt: startedAt, endedAt: nil, source: .live, device: device,
            language: configuration.language, tracks: [], pauses: [], bookmarks: [], status: .recording,
            silenceWarning: false, autonoteVersion: AutoNoteVersion.current)
        try await manifests.save(initial)

        meetingID = id; self.clock = clock; self.startedAt = startedAt
        saver = ManifestSaver(store: manifests, initial: initial)
        monitor = SilenceMonitor(start: .zero); silenceWarning = false
        stats = [.mic: TrackStatistics(), .system: TrackStatistics()]
        writers = TrackWriters(meetingDirectory: paths.meetingDirectory(id))
        do {
            let (changes, failures) = writers.transition { try $0.open(at: .zero) }
            if let (_, error) = failures.first { throw error }
            try await persist { $0.apply(changes) }
        } catch {
            await abandonStart(id)
            throw error
        }

        let queue = ChunkQueue()
        self.queue = queue; processed = 0
        consumer = Task { await self.consume(queue.stream) }

        // Microphone first: a permission refusal must stop the start before system audio is touched.
        var micError: (any Error)?
        var systemError: (any Error)?
        let mic = sources.makeMicrophoneSource(deviceUID: configuration.microphoneUID, clock: clock)
        do {
            try await mic.start(onBuffer: queue.onBuffer(for: .mic))
            micSource = mic
        } catch AudioSourceError.microphonePermission(let status) {
            await abandonStart(id)
            throw RecordingError.microphonePermission(status)
        } catch {
            micError = error
        }
        let system = sources.makeSystemSource(clock: clock)
        do {
            try await system.start(onBuffer: queue.onBuffer(for: .system))
            systemSource = system
        } catch {
            systemError = error
        }
        if let micError, let systemError {
            await abandonStart(id)
            throw RecordingError.allSourcesFailed("\(String(describing: micError)); \(String(describing: systemError))")
        }

        state = .recording(id)
        broadcaster.yield(.started(id))
        for (track, error) in [(Track.mic, micError), (.system, systemError)] {
            if let error { await reportFailure(track, error) }
        }
        ticker = makeTicker(for: id)
        return id
    }

    /// Undoes a start that never reached `.recording`: no source is running at this point.
    private func abandonStart(_ id: MeetingID) async {
        await drainPipeline()
        _ = writers.transition { try $0.close(at: .zero) }   // the directory is deleted next; failures do not matter
        await saver?.flush()
        do { try await manifests.delete(id) } catch { Self.log("delete abandoned meeting", error) }
        clearMeeting()
    }

    private func performStop(reason: StopReason) async throws -> Manifest {
        let (_, clock) = try active()
        guard let saver else { throw RecordingError.notRecording }
        let end = clock.now()
        let running = [micSource, systemSource].compactMap { $0 }
        micSource = nil; systemSource = nil
        await withTaskGroup(of: Void.self) { group in   // each source returns within its own stop timeout
            for source in running { group.addTask { await source.stop() } }
        }
        ticker?.cancel()   // not awaited: a tick in flight re-checks the meeting after its awaits (see `tick()`)
        await drainPipeline()

        let (changes, failures) = writers.transition { try $0.close(at: end) }
        await reportWriterFailures(failures)
        let endedAt = startedAt.addingTimeInterval(end.seconds)
        let status: MeetingStatus = end.seconds < Self.minimumDurationSeconds ? .tooShort : .recorded
        let finish: @Sendable (inout Manifest) -> Void = { m in
            if let i = m.pauses.lastIndex(where: { $0.end == nil }) { m.pauses[i].end = end }
            m.apply(changes)
            m.endedAt = endedAt
            m.status = status
        }
        let result: Result<Manifest, any Error>
        do {
            result = .success(try await saver.enqueue(finish).value.get())
        } catch {
            // The on-disk manifest stays `.recording`; crash recovery repairs it at the next launch.
            Self.log("final manifest save", error)
            var manifest = saver.latest
            finish(&manifest)
            result = .failure(error)
            broadcaster.yield(.stopped(manifest, reason))
        }
        if case .success(let manifest) = result { broadcaster.yield(.stopped(manifest, reason)) }
        for subscriber in audioSubscribers.values { subscriber.continuation.finish() }
        audioSubscribers = [:]
        clearMeeting()
        return try result.get()
    }

    private func clearMeeting() {
        state = .idle
        meetingID = nil; clock = nil; monitor = nil; writers = TrackWriters(); saver = nil
        micSource = nil; systemSource = nil; ticker = nil
        queue = nil; consumer = nil
    }

    private func makeTicker(for id: MeetingID) -> Task<Void, Never> {
        let interval = tickInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.scheduledTick(id)
            }
        }
    }

    /// A ticker cancelled by `stop` may still wake once; it must not tick the next meeting.
    private func scheduledTick(_ id: MeetingID) async {
        guard meetingID == id else { return }
        await tick()
    }

    // MARK: - Helpers

    /// The current meeting, or `.notRecording` when idle.
    private func active() throws -> (MeetingID, MeetingClock) {
        guard state != .idle, let meetingID, let clock else { throw RecordingError.notRecording }
        return (meetingID, clock)
    }

    /// The first failure of a track's writer is reported; that track's later chunks are dropped.
    func reportWriterFailures(_ failures: [(Track, any Error)]) async {
        for (track, error) in failures where writers.markFailed(track) {
            await reportFailure(track, error)
        }
    }

    /// `.sourceFailed` plus the manifest's `silenceWarning` flag.
    private func reportFailure(_ track: Track, _ error: any Error) async {
        Self.log("\(track.rawValue) source", error)
        broadcaster.yield(.sourceFailed(track, message: String(describing: error)))
        guard !silenceWarning else { return }
        silenceWarning = true
        do { try await persist { $0.silenceWarning = true } } catch { Self.log("silence flag save", error) }
    }

    @discardableResult
    func persist(_ body: @escaping @Sendable (inout Manifest) -> Void) async throws -> Manifest {
        guard let saver else { throw RecordingError.notRecording }
        return try await saver.enqueue(body).value.get()   // enqueued synchronously, so actor call order is kept
    }

    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        if !gate.tryEnter() { await withCheckedContinuation { gate.wait($0) } }
        defer { gate.leave() }
        return try await body()
    }

    static func log(_ what: String, _ error: any Error) {
        logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}
