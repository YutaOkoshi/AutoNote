import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

/// A real `MicrophoneSource` on a fake engine inside a real `RecordingSession`.
private final class EngineSourceFactory: AudioSourceFactory, @unchecked Sendable {
    let engine: FakeMicrophoneEngine
    let system = FakeAudioSource(track: .system)
    init(engine: FakeMicrophoneEngine) { self.engine = engine }
    func makeSystemSource(clock: MeetingClock) -> any AudioSource { system }
    func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource { makeRecoveringMicSource(engine, clock) }
    func inputDevice(uid: String?) -> DeviceRef? { FakeAudioSourceFactory.defaultInput }
}

@Suite struct RecordingSessionMicrophoneRecoveryTests {
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
