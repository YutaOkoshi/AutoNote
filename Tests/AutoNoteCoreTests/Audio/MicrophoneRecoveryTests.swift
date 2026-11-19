import Testing
import Foundation
import CoreAudio
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

/// The Bluetooth headset case (A2DP → HFP while the engine starts) played by `FakeMicrophoneEngine`: the engine stops
/// itself right after `start`, the hardware format changes, or callbacks never come.
private final class Chunks: Sendable {
    private let chunks = Mutex<[AudioChunk]>([])
    var all: [AudioChunk] { chunks.withLock { $0 } }
    var onBuffer: @Sendable (AudioChunk) -> Void { { chunk in self.chunks.withLock { $0.append(chunk) } } }
    func samples(from: Double, to: Double) -> [Int16] {
        all.filter { $0.start.seconds >= from && $0.start.seconds < to }.flatMap(\.samples)
    }
}

private final class FailureMessage: Sendable {
    private let value = Mutex<String?>(nil)
    var message: String? { value.withLock { $0 } }
    func set(_ m: String) { value.withLock { $0 = m } }
}

let micRecoveryTestPolicy = MicrophoneRecoveryPolicy(checkInterval: .milliseconds(20), settleDelay: .milliseconds(30),
                                            stallTimeout: .milliseconds(250), retryDelay: .milliseconds(30),
                                            maxConsecutiveFailures: 3, maxRebuilds: 30)

func eventuallyTrue(_ limit: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func makeRecoveringMicSource(_ engine: FakeMicrophoneEngine, _ clock: MeetingClock, policy: MicrophoneRecoveryPolicy = micRecoveryTestPolicy) -> MicrophoneSource {
    MicrophoneSource(deviceUID: nil, clock: clock, permission: FakeMicrophonePermission(.authorized), engine: engine,
                     lookup: FakeDeviceLookup(), policy: policy)
}

/// Pushes 50 ms of input every 20 ms of wall time, advancing host time, until cancelled.
private func feed(_ engine: FakeMicrophoneEngine, host: FakeHostClock, from: Double) -> Task<Void, Never> {
    Task.detached {
        var t = from
        while !Task.isCancelled {
            let frames = Int(engine.format.sampleRate * 0.05)
            engine.push(frames: frames, hostTime: host.hostTime(atSeconds: t), value: 0.25)
            t += 0.05
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite struct MicrophoneRecoveryTests {
    @Test func restartsWhenTheEngineStopsItselfRightAfterStart() async throws {
        let host = FakeHostClock(); let clock = MeetingClock.fake(host)
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1
        let out = Chunks()
        let src = makeRecoveringMicSource(engine, clock)
        try await src.start(onBuffer: out.onBuffer)
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        engine.push(frames: 48_000, hostTime: host.hostTime(atSeconds: 3.0), value: 0.25)
        await src.stop()

        let total = out.all.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 16_000) <= 48)
        let first = try #require(out.all.first)
        #expect(abs(first.start.seconds - 3.0) <= 0.02)   // stamped with host time: the gap before it stays a gap
        #expect(src.health?.restarts == 1)
        #expect(engine.isStopped)
    }

    @Test(arguments: [InputFormat(sampleRate: 16_000, channels: 1), InputFormat(sampleRate: 44_100, channels: 2),
                      InputFormat(sampleRate: 24_000, channels: 2)])
    func rebuildsForTheNewFormatAndStillWrites16kMono(newFormat: InputFormat) async throws {
        let host = FakeHostClock(); let clock = MeetingClock.fake(host)
        let engine = FakeMicrophoneEngine()   // 48 kHz / 1 ch (A2DP side)
        let out = Chunks()
        let src = makeRecoveringMicSource(engine, clock)
        try await src.start(onBuffer: out.onBuffer)
        engine.push(frames: 48_000, hostTime: host.hostTime(atSeconds: 0), value: 0.25)
        #expect(await eventuallyTrue { !out.all.isEmpty })
        engine.simulateConfigurationChange(stopEngine: true, newFormat: newFormat)
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        engine.push(frames: Int(newFormat.sampleRate), hostTime: host.hostTime(atSeconds: 2.0), value: 0.25)
        await src.stop()

        let before = out.samples(from: 0, to: 1.5)
        let after = out.samples(from: 2.0, to: 10)
        #expect(abs(before.count - 16_000) <= 48)
        try #require(abs(after.count - 16_000) <= 48)
        // Equal channels average to the same mono value: 0.25 → 8192.
        let middle = after[after.count / 2]
        #expect(abs(Int(middle) - 8192) <= 82)
        #expect(out.all.allSatisfy { $0.track == .mic })
        #expect(src.health?.restarts == 1)
    }

    @Test func rebuildsWhenNoCallbackArrives() async throws {
        let engine = FakeMicrophoneEngine()   // runs, but nothing is pushed: zero callbacks
        let src = makeRecoveringMicSource(engine, .fake())
        try await src.start { _ in }
        #expect(await eventuallyTrue { engine.startCount >= 2 })
        await src.stop()
        #expect((src.health?.restarts ?? 0) >= 1)
    }

    @Test func keepsTheEngineWhileCallbacksFlow() async throws {
        let host = FakeHostClock()
        let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host))
        try await src.start { _ in }
        let feeder = feed(engine, host: host, from: 0)
        try await Task.sleep(for: .milliseconds(700))   // well past stallTimeout
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(engine.startCount == 1)
        #expect(src.health?.restarts == 0)
    }

    @Test func aConfigurationChangeWithTheEngineStillRunningKeepsIt() async throws {
        let host = FakeHostClock()
        let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host))
        try await src.start { _ in }
        let feeder = feed(engine, host: host, from: 0)
        try await Task.sleep(for: .milliseconds(60))
        engine.simulateConfigurationChange(stopEngine: false)   // "posting notification" only; same format
        try await Task.sleep(for: .milliseconds(300))
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(engine.startCount == 1)
    }

    @Test func retriesAfterAFailedPrepareAndRecovers() async throws {
        let host = FakeHostClock()
        let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host))
        try await src.start { _ in }
        engine.failPrepare(1, with: AudioSourceError.coreAudio(call: "AudioUnitSetProperty", status: -1))
        engine.simulateConfigurationChange(stopEngine: true)
        #expect(await eventuallyTrue { engine.prepareCount == 3 && engine.isRunning })
        await src.stop()
        #expect(src.health?.restarts == 2)
    }

    @Test func givesUpAfterTheLimitAndReportsAFailureOnce() async throws {
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1_000
        let src = makeRecoveringMicSource(engine, .fake())
        let failure = FailureMessage()
        src.health?.setFailureObserver { failure.set($0) }
        try await src.start { _ in }
        #expect(await eventuallyTrue { failure.message != nil })
        let starts = engine.startCount
        #expect(starts == 1 + micRecoveryTestPolicy.maxConsecutiveFailures)
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.startCount == starts)   // no more attempts after giving up
        await src.stop()
        #expect(engine.isStopped)
    }

    @Test func stopDuringARebuildLeavesTheEngineStopped() async throws {
        let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake())
        try await src.start { _ in }
        engine.simulateConfigurationChange(stopEngine: true)
        try await Task.sleep(for: .milliseconds(45))   // around the settle delay
        await src.stop()
        let starts = engine.startCount
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.startCount == starts)
        #expect(!engine.isRunning)
    }
}

@Suite struct SourceHealthTests {
    @Test func tellsMissingCallbacksFromZeroSamples() {
        let h = SourceHealth()
        h.recordCallback(start: 0, duration: 1, nonZero: true)       // second 0: audio
        h.recordCallback(start: 1, duration: 0.5, nonZero: false)    // second 1: zeros
        h.recordCallback(start: 1.5, duration: 0.5, nonZero: false)
        // second 2 and 3: nothing
        h.recordCallback(start: 4, duration: 1, nonZero: false)      // second 4: zeros
        let s = SourceHealth.summary(track: .system, sources: [h], endSeconds: 5)
        #expect(s.noCallbackSeconds == 2)
        #expect(s.zeroSeconds == 2)
        #expect(s.callbacks == 4)
        #expect(s.restarts == 0)
    }

    @Test func mergesTheSourcesOfOneTrack() {
        let a = SourceHealth(), b = SourceHealth()
        a.recordCallback(start: 0, duration: 2, nonZero: true)
        b.recordCallback(start: 3, duration: 1, nonZero: true)
        b.noteRestart()
        let s = SourceHealth.summary(track: .mic, sources: [a, b], endSeconds: 4.2)
        #expect(s.noCallbackSeconds == 2)   // seconds 2 and 4 (the partial last second counts)
        #expect(s.zeroSeconds == 0)
        #expect(s.restarts == 1)
    }

    @Test func reportsAFailureToALateObserverOnce() {
        let h = SourceHealth()
        h.reportFailure("first")
        h.reportFailure("second")
        let got = Mutex<[String]>([])
        h.setFailureObserver { m in got.withLock { $0.append(m) } }
        #expect(got.withLock { $0 } == ["first"])
    }
}
