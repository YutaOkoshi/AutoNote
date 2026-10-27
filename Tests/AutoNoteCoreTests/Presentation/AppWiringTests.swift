import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

private func m(_ status: MeetingStatus) -> Manifest {
    var manifest = Samples.manifest
    manifest.status = status
    return manifest
}

/// A stream that already holds `events` and then ends, so `run()` returns once everything is handled.
private func finished(_ events: [RecordingEvent]) -> AsyncStream<RecordingEvent> {
    let (stream, continuation) = AsyncStream<RecordingEvent>.makeStream()
    for e in events { continuation.yield(e) }
    continuation.finish()
    return stream
}

private actor EventLog {
    private(set) var events: [RecordingEvent] = []
    func append(_ e: RecordingEvent) { events.append(e) }
}

private actor Counter {
    private(set) var settings: [Settings] = []
    func add(_ s: Settings) { settings.append(s) }
}

private struct Wiring {
    let wiring: AppWiring
    let enqueuer = FakeEnqueuer()
    let notifier = FakeUserNotifier()

    init(events: [RecordingEvent] = [], listeners: [@Sendable (RecordingEvent) async -> Void] = [],
         onQueueInputsChanged: @Sendable @escaping (Settings) async -> Void = { _ in }) {
        let stream = finished(events)
        wiring = AppWiring(events: { stream }, enqueuer: enqueuer, notifier: notifier, listeners: listeners,
                           onQueueInputsChanged: onQueueInputsChanged)
    }
}

/// 16 kHz mono 16-bit silence.
private func silentWAV(_ url: URL, seconds: Int) throws {
    let bytes = seconds * 16_000 * 2
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: bytes) + Data(count: bytes)).write(to: url)
}

private struct LiveFixture {
    let paths: AppPaths
    let mic = FakeLiveTranscriber(script: [u(1, .unknown, "おはようございます")])
    let system = FakeLiveTranscriber(script: [u(2, .unknown, "よろしくお願いします")])
    let micChunks: AsyncStream<AudioChunk>
    let micInput: AsyncStream<AudioChunk>.Continuation
    let systemChunks: AsyncStream<AudioChunk>
    let systemInput: AsyncStream<AudioChunk>.Continuation
    let live: LiveTranscriptionWiring

    init() throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        self.paths = paths
        (micChunks, micInput) = AsyncStream<AudioChunk>.makeStream()
        (systemChunks, systemInput) = AsyncStream<AudioChunk>.makeStream()
        let micStream = micChunks, systemStream = systemChunks
        let mic = self.mic, system = self.system
        live = LiveTranscriptionWiring(
            audio: { $0 == .mic ? micStream : systemStream },
            makeFeed: { id in
                let feed = LiveFeed(transcribers: [.mic: mic, .system: system], replacer: Replacer([]),
                                    liveJSON: paths.transcriptFile(id, .live), engineName: "Fake Live")
                return LiveFeedStart(feed: feed, language: .ja, hints: ["議事録"])
            })
    }
}

/// The first value of `stream` that satisfies `condition`, or nil after 2 s.
private func first<T: Sendable>(_ stream: AsyncStream<T>, where condition: @Sendable @escaping (T) -> Bool) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where condition(value) { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@Suite struct AppWiringTests {
    private let id = Samples.manifest.id

    // events に .stopped(m(.recorded), .manual) → enqueuer.ids == [id]、notifier.posted == []
    @Test func stoppedRecordedIsEnqueued() async {
        let w = Wiring(events: [.started(id), .stopped(m(.recorded), .manual)])
        await w.wiring.run()
        #expect(await w.enqueuer.ids == [id])
        #expect(await w.notifier.posted == [])
    }

    // .stopped(m(.tooShort), .manual) → ids == []、posted == [.recordingTooShort(id)]
    @Test func stoppedTooShortIsNotEnqueued() async {
        let w = Wiring(events: [.started(id), .stopped(m(.tooShort), .manual)])
        await w.wiring.run()
        #expect(await w.enqueuer.ids == [])
        #expect(await w.notifier.posted == [.recordingTooShort(id)])
    }

    // .stopped(m(.recorded), .diskFull) → enqueue（reason ではなく status で決める）
    @Test func diskFullStopUsesStatusToo() async {
        let w = Wiring(events: [.stopped(m(.recorded), .diskFull)])
        await w.wiring.run()
        #expect(await w.enqueuer.ids == [id])
        #expect(await w.notifier.posted == [])
    }

    // Other statuses are only logged: neither enqueued nor notified.
    @Test func otherStatusesAreOnlyLogged() async {
        let w = Wiring(events: [.stopped(m(.recording), .appTerminating), .stopped(m(.minutesGenerated), .manual)])
        await w.wiring.run()
        #expect(await w.enqueuer.ids == [])
        #expect(await w.notifier.posted == [])
    }

    // listener 2 つ → どちらも [.started, .bookmarked, .stopped] を受ける
    @Test func listenersSeeEveryEvent() async {
        let a = EventLog(), b = EventLog()
        let events: [RecordingEvent] = [.started(id), .bookmarked(Bookmark(at: TimelineTime(seconds: 3))),
                                        .stopped(m(.recorded), .manual)]
        let w = Wiring(events: events, listeners: [{ await a.append($0) }, { await b.append($0) }])
        await w.wiring.run()
        #expect(await a.events == events)
        #expect(await b.events == events)
        #expect(await w.enqueuer.ids == [id])
    }

    // X7: a slow listener does not hold back route/enqueue (each listener has its own FIFO consumer).
    @Test func slowListenerDoesNotDelayRoute() async throws {
        let (stream, input) = AsyncStream<RecordingEvent>.makeStream()
        let enqueuer = FakeEnqueuer()
        let slow = EventLog(), fast = EventLog()
        let wiring = AppWiring(events: { stream }, enqueuer: enqueuer, notifier: FakeUserNotifier(),
                               listeners: [{ e in try? await Task.sleep(for: .seconds(30)); await slow.append(e) },
                                           { await fast.append($0) }])
        let running = Task { await wiring.run() }
        let events: [RecordingEvent] = [.started(id), .stopped(m(.recorded), .manual)]
        for e in events { input.yield(e) }
        try await waitUntil { await enqueuer.ids == [id] }
        try await waitUntil { await fast.events == events }
        #expect(await slow.events == [])
        // Cancelling run() ends it (the slow listener's sleep is cancelled too).
        running.cancel()
        try await withTimeout(.seconds(2)) { await running.value }
    }

    // MeetingsAdapter(route: wiring.route).importAudio(3 秒の WAV) → ids == [新しい id]
    @Test func importedManifestIsRouted() async throws {
        let w = Wiring()
        let paths = AppPaths(root: try TemporaryDirectory.make())
        try paths.createBaseDirectories()
        let manifests = ManifestStore(paths: paths)
        let wiring = w.wiring
        let meetings = MeetingsAdapter(paths: paths, manifests: manifests, settings: SettingsStore(paths: paths),
                                       output: OutputFolderServices(paths: paths, services: SharedVaultServices()),
                                       importer: AudioImporter(paths: paths, manifests: manifests),
                                       crashRecovery: CrashRecovery(paths: paths, manifests: manifests),
                                       route: { await wiring.route($0) })
        let wav = try TemporaryDirectory.make().appending(path: "imported.wav")
        try silentWAV(wav, seconds: 3)
        let newID = try await meetings.importAudio(wav, startedAt: Samples.start)
        #expect(await w.enqueuer.ids == [newID])
        #expect(await w.notifier.posted == [])
    }

    // status .recording の manifest に 61 秒の無音 WAV → meetings.recover(id) → ids == [id]。
    // トラックなし → ids == []、posted == [.recordingTooShort(id)]
    @Test func recoverYesRoutesRecoveredManifest() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        try paths.createBaseDirectories()
        let manifests = ManifestStore(paths: paths)
        func adapter(_ w: Wiring) -> MeetingsAdapter {
            let wiring = w.wiring
            return MeetingsAdapter(paths: paths, manifests: manifests, settings: SettingsStore(paths: paths),
                                   output: OutputFolderServices(paths: paths, services: SharedVaultServices()),
                                   importer: AudioImporter(paths: paths, manifests: manifests),
                                   crashRecovery: CrashRecovery(paths: paths, manifests: manifests),
                                   route: { await wiring.route($0) })
        }

        var interrupted = m(.recording)
        interrupted.endedAt = nil
        interrupted.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: TimelineTime(seconds: 0))]
        try silentWAV(paths.meetingDirectory(id).appending(path: "tracks/mic-000.wav"), seconds: 61)
        try await manifests.save(interrupted)
        let yes = Wiring()
        try await adapter(yes).recover(id)
        #expect(await yes.enqueuer.ids == [id])
        #expect(await yes.notifier.posted == [])

        var empty = m(.recording)
        empty.endedAt = nil
        empty.tracks = []
        try await manifests.save(empty)
        let none = Wiring()
        try await adapter(none).recover(id)
        #expect(await none.enqueuer.ids == [])
        #expect(await none.notifier.posted == [.recordingTooShort(id)])
    }

    // outputFolder か finalEngine か finalModel が変わる → onQueueInputsChanged 1 回。countdownSeconds だけ → 0 回
    @Test func queueInputsChangeRebuildsOnlyWhenNeeded() async {
        let counter = Counter()
        let w = Wiring(onQueueInputsChanged: { await counter.add($0) })
        let old = Settings()
        var folder = old; folder.outputFolder = "/tmp/Vault"
        var engine = old; engine.finalEngine = "whisper"
        var model = old; model.finalModel = "large-v3-turbo"
        var countdown = old; countdown.countdownSeconds = 10
        await w.wiring.settingsChanged(from: old, to: folder)
        #expect(await counter.settings == [folder])
        await w.wiring.settingsChanged(from: old, to: engine)
        #expect(await counter.settings == [folder, engine])
        await w.wiring.settingsChanged(from: old, to: model)
        #expect(await counter.settings == [folder, engine, model])
        await w.wiring.settingsChanged(from: old, to: countdown)
        await w.wiring.settingsChanged(from: old, to: old)
        #expect(await counter.settings.count == 3)
    }

    // makeFeed は FakeLiveTranscriber 2 本の LiveFeed（liveJSON = paths.transcriptFile(id, .live)）。.started(id) →
    // audio(.mic) に流した 2 チャンクが mic の fedChunks に届き、updates() に台本の発話。.stopped → live.json がある
    @Test func liveFeedGetsAudioAndWritesLiveJSON() async throws {
        let f = try LiveFixture()
        f.micInput.yield(AudioFixtures.tone(start: 0, seconds: 1))
        f.micInput.yield(AudioFixtures.tone(start: 1, seconds: 1))
        await f.live.handle(.started(id))
        try await waitUntil { await f.mic.fedChunks.count == 2 }
        #expect(await f.mic.startedWith?.0 == .ja)
        #expect(await f.mic.startedWith?.1 == ["議事録"])
        let shown = await first(await f.live.updates()) { $0.count == 2 }
        #expect(shown?.map(\.text) == ["おはようございます", "よろしくお願いします"])
        #expect(shown?.map(\.speaker) == [.me, .other])

        await f.live.handle(.stopped(m(.recorded), .manual))
        let saved = try AutoNoteJSON.decoder().decode(Transcript.self, from: Data(contentsOf: f.paths.transcriptFile(id, .live)))
        #expect(saved.utterances.map(\.text) == ["おはようございます", "よろしくお願いします"])
    }

    // .paused(10)・.resumed(20)・.bookmarked(25) → 最後の updates() の LiveFeed.isMarker が 2 件
    @Test func pauseAndBookmarkBecomeMarkers() async throws {
        let f = try LiveFixture()
        await f.live.handle(.started(id))
        await f.live.handle(.paused(TimelineTime(seconds: 10)))
        await f.live.handle(.resumed(TimelineTime(seconds: 20)))
        await f.live.handle(.bookmarked(Bookmark(at: TimelineTime(seconds: 25), note: "決定")))
        let shown = await first(await f.live.updates()) { $0.filter(LiveFeed.isMarker).count == 2 }
        #expect(shown?.filter(LiveFeed.isMarker).map(\.text) == [LiveFeed.pauseMarkerText, LiveFeed.bookmarkMarkerText("決定")])
        // A second subscriber gets the same latest snapshot on subscribe.
        let again = await first(await f.live.updates()) { _ in true }
        #expect(again?.filter(LiveFeed.isMarker).count == 2)
        await f.live.handle(.stopped(m(.recorded), .manual))
    }

    // A successful meeting, then one whose makeFeed fails → the display is cleared ([] published, latest empty).
    @Test func failedFeedClearsPreviousMeeting() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let mic = FakeLiveTranscriber(script: [u(1, .unknown, "前の会議")])
        let calls = EventLog()
        let live = LiveTranscriptionWiring(audio: { _ in AsyncStream { $0.finish() } }, makeFeed: { id in
            await calls.append(.started(id))
            guard await calls.events.count == 1 else { throw FakeError(message: "no live engine") }
            let feed = LiveFeed(transcribers: [.mic: mic], replacer: Replacer([]),
                                liveJSON: paths.transcriptFile(id, .live), engineName: "Fake Live")
            return LiveFeedStart(feed: feed, language: .ja, hints: [])
        })
        await live.handle(.started(id))
        let viewer = await live.updates()
        #expect(await first(viewer) { $0.map(\.text) == ["前の会議"] } != nil)
        await live.handle(.stopped(m(.recorded), .manual))
        await live.handle(.started(id))
        #expect(await first(viewer) { $0.isEmpty } != nil)
        #expect(await live.latest == [])
        #expect(await first(await live.updates()) { _ in true } == [])
    }

    // makeFeed が throw → updates() は空のまま、enqueue は通常どおり
    @Test func liveFeedFailureDoesNotBreakRecording() async {
        let live = LiveTranscriptionWiring(audio: { _ in AsyncStream { $0.finish() } },
                                           makeFeed: { _ in throw FakeError(message: "no live engine") })
        let w = Wiring(events: [.started(id), .paused(TimelineTime(seconds: 1)), .stopped(m(.recorded), .manual)],
                       listeners: [{ await live.handle($0) }])
        await w.wiring.run()
        #expect(await w.enqueuer.ids == [id])
        #expect(await live.latest == [])
    }

    // X9/C21: a real RecordingSession (fake sources) → RecordingSessionActivity → QueueAssembly.make with one BatchGate
    // shared by a FinalTranscriptionRunner. Recording pauses the gate; stopping resumes it (§13・overview §8b).
    @Test func batchGatePausedWhileRecording() async throws {
        let h = try await SessionHarness.make()
        let gate = BatchGate()
        let runner = FinalTranscriptionRunner(transcriber: FakeBatchTranscriber(results: [:]), engineName: "Fake Batch",
                                              paths: h.paths, gate: gate)
        let automations = AutomationsStage(
            dispatcher: AutomationDispatcher(file: AutomationsFile(url: h.paths.automationsFile),
                                             runner: AutomationRunner(logsDirectory: h.paths.logsDirectory,
                                                                      ledgerFile: h.paths.logsDirectory.appending(path: "ledger.json")),
                                             notifier: nil),
            vault: { nil })
        let queue = QueueAssembly.make(paths: h.paths, stages: [TranscribeStage(runner: runner)], automations: automations,
                                       activity: RecordingSessionActivity(session: h.session), gate: gate)
        #expect(await Set(queue.stages.keys) == [StageName.transcribe, StageName.automations])
        await queue.start()
        #expect(!gate.isPaused)
        _ = try await h.session.start(.init(language: .ja))
        try await waitUntil { gate.isPaused }
        _ = try await h.session.stop()
        try await waitUntil { !gate.isPaused }
        await queue.stop()
    }
}
