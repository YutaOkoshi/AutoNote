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

@Suite struct ProcessTapSourceTests {
    @Test func startCallsHardwareInOrder() async throws {
        let hw = FakeTapHardware(); let src = ProcessTapSource(clock: .fake(), hardware: hw, excludeBundleIDs: ["com.yutaokoshi.autonote"])
        try await src.start { _ in }
        #expect(hw.calls == ["createTap", "tapFormat", "createAggregate", "createIOProc", "start"])
        #expect(hw.lastTapSpec?.excludeBundleIDs == ["com.yutaokoshi.autonote"])
        await src.stop()
    }

    @Test func tapOnlyAggregateHasNoOutputDevice() {
        let d = ProcessTapSource.aggregateDescription(tapUUID: "T", layout: .tapOnly, outputUID: nil)
        #expect(d[kAudioAggregateDeviceSubDeviceListKey] == nil && d[kAudioAggregateDeviceMainSubDeviceKey] == nil)
        #expect(d[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true && d[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect((d[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix("com.yutaokoshi.autonote.tap.") == true)
    }

    @Test func failureMidwayTearsDownCreatedObjects() async {
        let hw = FakeTapHardware(); hw.failOn = "createAggregate"
        let error = await #expect(throws: AudioSourceError.self) { try await ProcessTapSource(clock: .fake(), hardware: hw).start { _ in } }
        #expect(hw.calls.suffix(1) == ["destroyTap"])
        #expect(hw.calls == ["createTap", "tapFormat", "createAggregate", "destroyTap"])
        #expect(error == .coreAudio(call: "createAggregate", status: -1))
    }

    @Test func failureAtStartTearsDownEverything() async {
        let hw = FakeTapHardware(); hw.failOn = "start"
        let error = await #expect(throws: AudioSourceError.self) { try await ProcessTapSource(clock: .fake(), hardware: hw).start { _ in } }
        #expect(hw.calls == ["createTap", "tapFormat", "createAggregate", "createIOProc", "start", "destroyIOProc", "destroyAggregate", "destroyTap"])
        #expect(error == .coreAudio(call: "start", status: -1))
    }

    @Test func secondStartThrowsAlreadyStarted() async throws {
        let hw = FakeTapHardware(); let src = ProcessTapSource(clock: .fake(), hardware: hw)
        try await src.start { _ in }
        await #expect(throws: AudioSourceError.alreadyStarted) { try await src.start { _ in } }
        #expect(hw.calls.filter { $0 == "createTap" }.count == 1)
        await src.stop()
    }

    @Test func stopTearsDownInOrder() async throws {
        let hw = FakeTapHardware(); let src = ProcessTapSource(clock: .fake(), hardware: hw)
        try await src.start { _ in }
        await src.stop()
        #expect(hw.calls.suffix(4) == ["stop", "destroyIOProc", "destroyAggregate", "destroyTap"])
    }

    @Test func deliversConvertedChunks() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); let out = ChunkCollector()
        let src = ProcessTapSource(clock: .fake(host), hardware: hw)
        try await src.start(onBuffer: out.onBuffer)
        for i in 0..<100 {
            hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: Double(i) * 0.01), sampleTime: Double(i * 480), value: 0.25)
        }
        await src.stop()
        let total = out.all.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 16_000) <= 48)
        #expect(out.all.allSatisfy { $0.track == .system })
    }

    @Test func chunkStartFollowsHostTimeAcrossGap() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); let out = ChunkCollector()
        let src = ProcessTapSource(clock: .fake(host), hardware: hw)
        try await src.start(onBuffer: out.onBuffer)
        for i in 0..<50 {
            hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: Double(i) * 0.01), sampleTime: Double(i * 480), value: 0.25)
        }
        for i in 0..<50 {
            hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: 5.0 + Double(i) * 0.01), sampleTime: Double((50 + i) * 480), value: 0.25)
        }
        await src.stop()
        let second = try #require(out.all.first { $0.start.seconds >= 4.0 })
        #expect(abs(second.start.seconds - 5.0) <= 0.02)
    }

    @Test func gapFlushesPreGapSamplesAtExpectedEnd() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); let out = ChunkCollector()
        let src = ProcessTapSource(clock: .fake(host), hardware: hw)
        try await src.start(onBuffer: out.onBuffer)
        for i in 0..<50 {
            hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: Double(i) * 0.01), sampleTime: Double(i * 480), value: 0.25)
        }
        for i in 0..<50 {
            hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: 5.0 + Double(i) * 0.01), sampleTime: Double((50 + i) * 480), value: 0.25)
        }
        await src.stop()
        // Record chunks before the gap start at 0.00 ... 0.49; the flushed tail starts at the expected end, 0.50.
        let gapChunk = try #require(out.all.first { $0.start.seconds > 0.495 && $0.start.seconds < 4.0 })
        #expect(abs(gapChunk.start.seconds - 0.5) <= 0.02)
        let total = out.all.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 16_000) <= 48)
    }

    @Test func stopReturnsWithinTimeoutWhenTeardownBlocks() async throws {
        let hw = FakeTapHardware(); hw.teardownDelay = .seconds(3)
        let src = ProcessTapSource(clock: .fake(), hardware: hw, stopTimeout: .milliseconds(200))
        try await src.start { _ in }
        let t0 = ContinuousClock.now; await src.stop()
        #expect(ContinuousClock.now - t0 < .seconds(1))
        let calls = hw.calls
        #expect(calls.contains("stop") && !calls.contains("destroyTap"))
    }

    @Test @MainActor func stopFromMainActorDoesNotBlockMainThread() async throws {
        let hw = FakeTapHardware(); hw.teardownDelay = .seconds(3)
        let src = ProcessTapSource(clock: .fake(), hardware: hw, stopTimeout: .milliseconds(200))
        try await src.start { _ in }
        let t0 = ContinuousClock.now; await src.stop()
        #expect(ContinuousClock.now - t0 < .seconds(1))
        let calls = hw.calls
        #expect(calls.contains("stop") && !calls.contains("destroyTap"))
    }

    @Test func statisticsCountCallbacksAndDrops() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware()
        let src = ProcessTapSource(clock: .fake(host), hardware: hw)
        try await src.start { _ in }
        for i in 0..<3 {
            hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: Double(i) * 0.01), sampleTime: Double(i * 480), value: 0.1)
        }
        await src.stop()
        let stats = await src.statistics()
        #expect(stats.callbacks == 3 && stats.frames == 1440 && stats.droppedFrames == 0)
    }
}
