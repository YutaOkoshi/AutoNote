import Foundation
import os

/// One live recording at a time: two sources → per-track segmented WAV writers, with the manifest kept current.
///
/// Public operations run one at a time (an internal FIFO gate), so a long `start` or `stop` never interleaves with a
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
    private static let tracks: [Track] = [.mic, .system]

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
    private var audioSubscribers: [Track: AsyncStream<AudioChunk>.Continuation] = [:]

    // Per meeting; set by `start`, cleared by `stop` or a failed start.
    private var meetingID: MeetingID?
    private var clock: MeetingClock?
    private var startedAt = Date(timeIntervalSince1970: 0)
    private var writers: [Track: WAVSegmentWriter] = [:]
    private var monitor: SilenceMonitor?
    private var silenceWarning = false
    private var stats: [Track: TrackStatistics] = [:]
    private var micSource: (any AudioSource)?
    private var systemSource: (any AudioSource)?
    private var ticker: Task<Void, Never>?

    // Chunk pipeline.
    private var queue: ChunkQueue?
    private var consumer: Task<Void, Never>?
    private var processed = 0
    private var idleWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private var saver: ManifestSaver?

    // FIFO gate for public operations.
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// A new subscription each call; every subscriber gets the same events from now on. Finished at `stop`.
    public func events() -> AsyncStream<RecordingEvent> { broadcaster.subscribe() }

    var subscriberCount: Int { broadcaster.count }

    public func elapsed() -> TimelineTime {
        guard state != .idle, let clock else { return .zero }
        return clock.now()
    }

    /// Live chunks of `track` for real-time transcription. Not fed while paused; finished at `stop`.
    /// Calling again finishes the previous stream.
    public func audio(for track: Track) -> AsyncStream<AudioChunk> {
        audioSubscribers[track]?.finish()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        audioSubscribers[track] = continuation
        return stream
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
            let changes = transitionWriters { try $0.close(at: at) }
            try await persist { $0.pauses.append(PauseInterval(start: at)); $0.apply(changes) }
            broadcaster.yield(.paused(at))
        }
    }

    public func resume() async throws {
        try await serialized {
            let (id, clock) = try active()
            guard case .paused = state else { throw RecordingError.notPaused }
            let at = clock.now()
            let changes = transitionWriters { try $0.open(at: at) }
            state = .recording(id)
            try await persist { m in
                if let i = m.pauses.lastIndex(where: { $0.end == nil }) { m.pauses[i].end = at }
                m.apply(changes)
            }
            broadcaster.yield(.resumed(at))
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

    /// Returns once every chunk accepted so far has been handled (written, forwarded, its manifest change saved).
    func waitUntilIdle() async {
        guard let queue else { return }
        let target = queue.enqueued
        guard processed < target else { return }
        await withCheckedContinuation { idleWaiters.append((target, $0)) }
    }

    /// Periodic work while recording (silence warnings; Task 11 adds disk checks).
    func tick() async {
        guard state != .idle, monitor != nil else { return }
        let paused = if case .paused = state { true } else { false }
        let warnings = monitor!.tick(now: elapsed(), paused: paused)
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
        try await manifests.save(Manifest(
            id: id, title: nil, startedAt: startedAt, endedAt: nil, source: .live, device: device,
            language: configuration.language, tracks: [], pauses: [], bookmarks: [], status: .recording,
            silenceWarning: false, autonoteVersion: AutoNoteVersion.current))

        meetingID = id; self.clock = clock; self.startedAt = startedAt
        saver = ManifestSaver(store: manifests, id: id)
        monitor = SilenceMonitor(start: .zero); silenceWarning = false
        stats = [.mic: TrackStatistics(), .system: TrackStatistics()]
        let directory = paths.meetingDirectory(id)
        writers = [.mic: WAVSegmentWriter(track: .mic, meetingDirectory: directory),
                   .system: WAVSegmentWriter(track: .system, meetingDirectory: directory)]
        do {
            var opened: [SegmentChange] = []
            for track in Self.tracks { opened += try writers[track]!.open(at: .zero) }
            let changes = opened
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
            guard let error else { continue }
            broadcaster.yield(.sourceFailed(track, message: String(describing: error)))
            silenceWarning = true
        }
        if silenceWarning {
            do { try await persist { $0.silenceWarning = true } } catch { Self.log("silence flag save", error) }
        }
        ticker = makeTicker()
        return id
    }

    /// Undoes a start that never reached `.recording`: no source is running at this point.
    private func abandonStart(_ id: MeetingID) async {
        await drainPipeline()
        _ = transitionWriters { try $0.close(at: .zero) }
        await saver?.flush()
        do { try await manifests.delete(id) } catch { Self.log("delete abandoned meeting", error) }
        clearMeeting()
    }

    private func performStop(reason: StopReason) async throws -> Manifest {
        let (_, clock) = try active()
        let end = clock.now()
        let running = [micSource, systemSource].compactMap { $0 }
        micSource = nil; systemSource = nil
        await withTaskGroup(of: Void.self) { group in   // each source returns within its own stop timeout
            for source in running { group.addTask { await source.stop() } }
        }
        ticker?.cancel()
        await ticker?.value
        await drainPipeline()

        let changes = transitionWriters { try $0.close(at: end) }
        let endedAt = startedAt.addingTimeInterval(end.seconds)
        let status: MeetingStatus = end.seconds < Self.minimumDurationSeconds ? .tooShort : .recorded
        let result: Result<Manifest, any Error>
        do {
            result = .success(try await persist { m in
                if let i = m.pauses.lastIndex(where: { $0.end == nil }) { m.pauses[i].end = end }
                m.apply(changes)
                m.endedAt = endedAt
                m.status = status
            })
        } catch {
            result = .failure(error)
        }
        if case .success(let manifest) = result { broadcaster.yield(.stopped(manifest, reason)) }
        broadcaster.finishAll()
        for continuation in audioSubscribers.values { continuation.finish() }
        audioSubscribers = [:]
        clearMeeting()
        return try result.get()
    }

    private func clearMeeting() {
        state = .idle
        meetingID = nil; clock = nil; monitor = nil; writers = [:]; saver = nil
        micSource = nil; systemSource = nil; ticker = nil
        queue = nil; consumer = nil
    }

    private func makeTicker() -> Task<Void, Never> {
        let interval = tickInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    // MARK: - Chunk pipeline

    private func consume(_ stream: AsyncStream<ChunkQueue.Element>) async {
        for await (track, chunk) in stream {
            await handle(chunk, from: track)
            processed += 1
            resumeIdleWaiters()
        }
        resumeIdleWaiters(all: true)
    }

    private func handle(_ incoming: AudioChunk, from track: Track) async {
        var chunk = incoming
        chunk.track = track
        monitor?.observe(track, chunk: chunk)
        if case .paused = state { return }
        guard writers[track]?.isOpen == true else { return }
        let changes: [SegmentChange]
        do {
            changes = try writers[track]!.write(chunk)
        } catch {
            Self.log("write \(track.rawValue)", error)
            return
        }
        stats[track, default: TrackStatistics()].add(chunk)
        audioSubscribers[track]?.yield(chunk)
        guard !changes.isEmpty else { return }
        do { try await persist { $0.apply(changes) } } catch { Self.log("segment save", error) }
    }

    /// Finishes the queue and waits until the consumer has handled everything in it.
    private func drainPipeline() async {
        queue?.finish()
        await consumer?.value
    }

    private func resumeIdleWaiters(all: Bool = false) {
        let ready = idleWaiters.filter { all || $0.target <= processed }
        idleWaiters.removeAll { all || $0.target <= processed }
        for waiter in ready { waiter.continuation.resume() }
    }

    // MARK: - Helpers

    /// The current meeting, or `.notRecording` when idle.
    private func active() throws -> (MeetingID, MeetingClock) {
        guard state != .idle, let meetingID, let clock else { throw RecordingError.notRecording }
        return (meetingID, clock)
    }

    /// Applies `body` to both writers; a failing writer is logged and skipped so the other still transitions.
    private func transitionWriters(_ body: (inout WAVSegmentWriter) throws -> [SegmentChange]) -> [SegmentChange] {
        var changes: [SegmentChange] = []
        for track in Self.tracks where writers[track] != nil {
            do { changes += try body(&writers[track]!) } catch { Self.log("writer \(track.rawValue)", error) }
        }
        return changes
    }

    @discardableResult
    private func persist(_ body: @escaping @Sendable (inout Manifest) -> Void) async throws -> Manifest {
        guard let saver else { throw RecordingError.notRecording }
        return try await saver.update(body)
    }

    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        if gateBusy {
            await withCheckedContinuation { gateWaiters.append($0) }   // ownership is handed over by `release`
        } else {
            gateBusy = true
        }
        defer {
            if gateWaiters.isEmpty { gateBusy = false } else { gateWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    private static func log(_ what: String, _ error: any Error) {
        logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}
