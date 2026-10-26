import Testing
import Foundation
import CoreAudio
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

/// Collects chunks handed to `onBuffer` from the drain task.
private final class ChunkCollector: Sendable {
    private let chunks = Mutex<[AudioChunk]>([])
    var all: [AudioChunk] { chunks.withLock { $0 } }
    var onBuffer: @Sendable (AudioChunk) -> Void { { chunk in self.chunks.withLock { $0.append(chunk) } } }
}

@Suite struct MicrophoneSourceTests {
    @Test(arguments: [MicrophonePermissionStatus.notDetermined, .denied, .restricted])
    func refusesWithoutPermissionAndNeverTouchesEngine(status: MicrophonePermissionStatus) async {
        let engine = FakeMicrophoneEngine()
        let src = MicrophoneSource(deviceUID: nil, clock: .fake(), permission: FakeMicrophonePermission(status), engine: engine, lookup: FakeDeviceLookup())
        await #expect(throws: AudioSourceError.microphonePermission(status)) { try await src.start { _ in } }
        #expect(engine.prepared == nil)
    }

    @Test func resolvesDeviceUIDAndPassesVoiceProcessing() async throws {
        let engine = FakeMicrophoneEngine()
        let src = MicrophoneSource(deviceUID: "USB-MIC:input", clock: .fake(), voiceProcessing: true,
                                   permission: FakeMicrophonePermission(.authorized), engine: engine,
                                   lookup: FakeDeviceLookup(devices: ["USB-MIC:input": 77]))
        try await src.start { _ in }
        #expect(engine.prepared?.deviceID == 77)
        #expect(engine.prepared?.voiceProcessing == true)
        await src.stop()
    }

    @Test func unknownUIDThrowsDeviceNotFound() async {
        let engine = FakeMicrophoneEngine()
        let src = MicrophoneSource(deviceUID: "GONE:input", clock: .fake(), permission: FakeMicrophonePermission(.authorized),
                                   engine: engine, lookup: FakeDeviceLookup(devices: ["USB-MIC:input": 77]))
        await #expect(throws: AudioSourceError.deviceNotFound(uid: "GONE:input")) { try await src.start { _ in } }
        #expect(engine.prepared == nil)
    }

    @Test func nilUIDUsesDefaultInput() async throws {
        let engine = FakeMicrophoneEngine()
        let src = MicrophoneSource(deviceUID: nil, clock: .fake(), permission: FakeMicrophonePermission(.authorized),
                                   engine: engine, lookup: FakeDeviceLookup(devices: ["USB-MIC:input": 77]))
        try await src.start { _ in }
        #expect(engine.prepared != nil)
        #expect(engine.prepared?.deviceID == nil)
        await src.stop()
    }

    @Test func voiceProcessingIsOffByDefault() async throws {
        let engine = FakeMicrophoneEngine()
        let src = MicrophoneSource(deviceUID: nil, clock: .fake(), permission: FakeMicrophonePermission(.authorized),
                                   engine: engine, lookup: FakeDeviceLookup())
        try await src.start { _ in }
        #expect(engine.prepared?.voiceProcessing == false)
        await src.stop()
    }

    @Test func deliversChunksAt16k() async throws {
        let host = FakeHostClock(); let clock = MeetingClock.fake(host)
        let engine = FakeMicrophoneEngine(); engine.format = InputFormat(sampleRate: 24_000, channels: 1)
        let out = ChunkCollector()
        let src = MicrophoneSource(deviceUID: nil, clock: clock, permission: FakeMicrophonePermission(.authorized),
                                   engine: engine, lookup: FakeDeviceLookup())
        try await src.start(onBuffer: out.onBuffer)
        let pushHost = host.hostTime(atSeconds: 1.5)
        engine.push(frames: 24_000, hostTime: pushHost, value: 0.25)
        await src.stop()
        let total = out.all.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 16_000) <= 48)
        let first = try #require(out.all.first)
        #expect(abs(first.start.seconds - clock.timeline(hostTime: pushHost).seconds) <= 0.02)
        #expect(out.all.allSatisfy { $0.track == .mic })
        #expect(engine.isStopped)
    }

    @Test func secondStartThrowsAlreadyStarted() async throws {
        let engine = FakeMicrophoneEngine()
        let src = MicrophoneSource(deviceUID: nil, clock: .fake(), permission: FakeMicrophonePermission(.authorized),
                                   engine: engine, lookup: FakeDeviceLookup())
        try await src.start { _ in }
        await #expect(throws: AudioSourceError.alreadyStarted) { try await src.start { _ in } }
        #expect(engine.prepareCount == 1)
        await src.stop()
    }

    @Test func stopReturnsWithinTimeoutWhenEngineStopBlocks() async throws {
        let engine = FakeMicrophoneEngine(); engine.stopDelay = .seconds(3)
        let src = MicrophoneSource(deviceUID: nil, clock: .fake(), permission: FakeMicrophonePermission(.authorized),
                                   engine: engine, lookup: FakeDeviceLookup(), stopTimeout: .milliseconds(200))
        try await src.start { _ in }
        let t0 = ContinuousClock.now; await src.stop()
        #expect(ContinuousClock.now - t0 < .seconds(1))
        #expect(!engine.isStopped)
    }
}
