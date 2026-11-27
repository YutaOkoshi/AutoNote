import Testing
import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

/// A real `MicrophoneSource` on a fake engine inside a real `RecordingSession`.
private final class EngineSourceFactory: AudioSourceFactory, @unchecked Sendable {
    let engine: FakeMicrophoneEngine
    let system = FakeAudioSource(track: .system)
    let policy: MicrophoneRecoveryPolicy
    init(engine: FakeMicrophoneEngine, policy: MicrophoneRecoveryPolicy = micRecoveryTestPolicy) { self.engine = engine; self.policy = policy }
    func makeSystemSource(clock: MeetingClock) -> any AudioSource { system }
    private let made = Mutex<MicrophoneSource?>(nil)
    /// The counters of the microphone source made last.
    var health: SourceHealth? { made.withLock { $0 }?.health }
    func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource {
        let source = makeRecoveringMicSource(engine, clock, policy: policy)
        made.withLock { $0 = source }
        return source
    }
    func inputDevice(uid: String?) -> DeviceRef? { FakeAudioSourceFactory.defaultInput }
}

/// A microphone that neither stalls nor rebuilds: these tests move the meeting clock by minutes at once.
private var steadyMicPolicy: MicrophoneRecoveryPolicy {
    var p = micRecoveryTestPolicy
    p.stallTimeout = .seconds(3600); p.zeroTimeout = nil
    return p
}

/// One second of sound per second of the meeting, `seconds` long from `from`; then the meeting clock is there too.
private func speak(_ engine: FakeMicrophoneEngine, host: FakeHostClock, from: Double, seconds: Int, health: SourceHealth?) async {
    let before = health?.callbacks ?? 0
    for i in 0..<seconds {
        engine.push(frames: Int(engine.format.sampleRate), hostTime: host.hostTime(atSeconds: from + Double(i)), value: 0.25)
        if i % 4 == 3 { try? await Task.sleep(for: .milliseconds(25)) }   // the ring holds 10 s: let the drain keep up
    }
    _ = await eventuallyTrue(.seconds(30)) { (health?.callbacks ?? 0) >= before + seconds }
    host.advance(Double(seconds))
}

@Suite struct RecordingSessionMicrophoneRecoveryTests {
    /// Auto-record's usual ending: the headset goes away, the microphone is detached, and the recording stops when
    /// the grace time is over. Nobody was to be recorded in that time, so it is not missing.
    @Test func theTimeAfterTheMicrophoneWasDetachedForGoodIsNotALoss() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let engine = FakeMicrophoneEngine(); let host = FakeHostClock()
        let factory = EngineSourceFactory(engine: engine, policy: steadyMicPolicy)
        let session = RecordingSession(paths: paths, manifests: ManifestStore(paths: paths), sources: factory, host: host,
                                       disk: FakeDiskSpace(), now: { Samples.start }, tickInterval: .seconds(3600), timeZone: Samples.tokyo)
        _ = try await session.start(.init(language: .ja))
        #expect(await eventuallyTrue { engine.isRunning })
        await speak(engine, host: host, from: 0, seconds: 100, health: factory.health)
        try await session.detachMicrophone()
        host.advance(30)                                    // the grace time
        let m = try await session.stop()

        let mic = try #require(m.audioHealth?.first { $0.track == .mic })
        #expect(mic.noCallbackSeconds >= 29 && mic.noCallbackSeconds <= 31)     // counted as before…
        #expect(mic.excludedNoCallbackSeconds == mic.noCallbackSeconds)         // …and all of it set aside
        #expect(m.audioLoss == nil)
    }

    /// Detached in the middle and back later: what was said in between is missing, and stays a loss.
    @Test func aMicrophoneThatWasAwayAndCameBackLostTheTimeBetween() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let engine = FakeMicrophoneEngine(); let host = FakeHostClock()
        let factory = EngineSourceFactory(engine: engine, policy: steadyMicPolicy)
        let session = RecordingSession(paths: paths, manifests: ManifestStore(paths: paths), sources: factory, host: host,
                                       disk: FakeDiskSpace(), now: { Samples.start }, tickInterval: .seconds(3600), timeZone: Samples.tokyo)
        _ = try await session.start(.init(language: .ja))
        #expect(await eventuallyTrue { engine.isRunning })
        await speak(engine, host: host, from: 0, seconds: 100, health: factory.health)
        try await session.detachMicrophone()
        host.advance(60)
        try await session.attachMicrophone(deviceUID: nil)
        #expect(await eventuallyTrue { engine.isRunning })
        await speak(engine, host: host, from: 160, seconds: 100, health: factory.health)
        let m = try await session.stop()

        let mic = try #require(m.audioHealth?.first { $0.track == .mic })
        #expect(mic.noCallbackSeconds >= 59 && mic.noCallbackSeconds <= 61)
        #expect(mic.excludedNoCallbackSeconds == nil)
        let loss = try #require(m.audioLoss)
        #expect(loss.count == 1 && loss.first?.track == .mic && loss.first?.sourceFailed == false)
        #expect((loss.first?.seconds ?? 0) >= 59 && (loss.first?.seconds ?? 0) <= 61)
    }

    @Test func theStoppedStretchIsSilenceAndTheManifestCountsIt() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let manifests = ManifestStore(paths: paths)
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1   // the A2DP → HFP case
        let factory = EngineSourceFactory(engine: engine)
        let host = FakeHostClock()
        let session = RecordingSession(paths: paths, manifests: manifests, sources: factory, host: host, disk: FakeDiskSpace(),
                                       now: { Samples.start }, tickInterval: .seconds(3600), timeZone: Samples.tokyo)
        _ = try await session.start(.init(language: .ja))
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        engine.push(frames: 48_000, hostTime: host.hostTime(atSeconds: 1.0), value: 0.25)   // 1.0 ..< 2.0 s
        try await Task.sleep(for: .milliseconds(100))
        host.advance(4.0)
        let m = try await session.stop()

        let files = m.tracks.filter { $0.track == .mic }.sorted { $0.startOffset < $1.startOffset }
        let samples = try files.flatMap { try WAVFile.readSamples(paths.meetingDirectory(m.id).appending(path: $0.relativePath)) }
        try #require(abs(samples.count - 64_000) <= 16)
        #expect(samples[0..<15_900].allSatisfy { $0 == 0 })              // engine dead: silence, not a shift
        #expect(samples[16_200..<31_800].allSatisfy { abs(Int($0) - 8192) <= 82 })
        #expect(samples[32_200...].allSatisfy { $0 == 0 })

        let mic = try #require(m.audioHealth?.first { $0.track == .mic })
        #expect(mic.restarts == 1)
        #expect(mic.noCallbackSeconds == 3)   // seconds 0, 2, 3
        #expect(mic.zeroSeconds == 0)
        #expect(m.audioHealth?.contains { $0.track == .system } == false)   // the fake system source keeps no counters
        #expect(m.audioLoss == nil)           // three seconds are far below the threshold

        let saved = try String(contentsOf: paths.meetingDirectory(m.id).appending(path: "manifest.json"), encoding: .utf8)
        #expect(saved.contains("\"audio_health\""))
        #expect(saved.contains("\"no_callback_seconds\""))
        #expect(try await manifests.load(m.id) == m)
    }

    /// The input never comes back: still silence in the file, and now also on record as lost audio.
    @Test func aMicrophoneThatGaveUpIsALossInTheManifestAndAnEvent() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let manifests = ManifestStore(paths: paths)
        let engine = FakeMicrophoneEngine()   // never pushes: every rebuild stalls
        let factory = EngineSourceFactory(engine: engine)
        let host = FakeHostClock()
        let session = RecordingSession(paths: paths, manifests: manifests, sources: factory, host: host, disk: FakeDiskSpace(),
                                       now: { Samples.start }, tickInterval: .seconds(3600), timeZone: Samples.tokyo)
        let events = await session.events()
        _ = try await session.start(.init(language: .ja))
        #expect(await eventuallyTrue(.seconds(10)) { engine.isStopped && engine.startCount == 4 })   // gave up after 3 rebuilds
        try await Task.sleep(for: .milliseconds(100))
        host.advance(20)
        let m = try await session.stop()

        let samples = try m.tracks.filter { $0.track == .mic }.flatMap {
            try WAVFile.readSamples(paths.meetingDirectory(m.id).appending(path: $0.relativePath))
        }
        #expect(abs(samples.count - 320_000) <= 16 && samples.allSatisfy { $0 == 0 })   // filled with silence, as before
        #expect(m.audioLoss == [TrackLoss(track: .mic, seconds: 20, sourceFailed: true)])
        let received = await eventsUntilStopped(events)
        #expect(received.contains { if case .sourceFailed(.mic, _) = $0 { true } else { false } })
        let saved = try String(contentsOf: paths.meetingDirectory(m.id).appending(path: "manifest.json"), encoding: .utf8)
        #expect(saved.contains("\"audio_loss\""))
        #expect(try await manifests.load(m.id) == m)
    }
}
