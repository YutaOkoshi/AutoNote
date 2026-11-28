import Testing
import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

private final class Level: Sendable {
    private let value = Mutex<Float>(0)
    var current: Float { value.withLock { $0 } }
    func set(_ v: Float) { value.withLock { $0 = v } }
}

/// Pushes 50 ms of input at `level` every 5 ms of wall time, advancing host time, until cancelled.
private func feed(_ engine: FakeMicrophoneEngine, host: FakeHostClock, level: Level) -> Task<Void, Never> {
    Task.detached {
        var t = 0.0
        while !Task.isCancelled {
            let frames = Int(engine.format.sampleRate * 0.05)
            engine.push(frames: frames, hostTime: host.hostTime(atSeconds: t), value: level.current)
            t += 0.05
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The microphone's zero watch in short: a rebuild after 150 ms of exact zeros, then waits of 300 and 600 ms; three
/// rebuilds per stretch of zeros, as in production. The times are the source's clock, which the tests move
/// (`StepClock`): with the real one, a feeder held up for 150 ms looked like a muted microphone.
private func zeroPolicy(_ tweak: (inout MicrophoneRecoveryPolicy) -> Void = { _ in }) -> MicrophoneRecoveryPolicy {
    var p = micRecoveryTestPolicy
    p.zeroTimeout = .milliseconds(150)
    p.zeroRetryMax = .seconds(5)
    p.maxZeroRebuilds = MicrophoneRecoveryPolicy.standard.maxZeroRebuilds
    tweak(&p)
    return p
}

/// An input that calls back with nothing but exact zeros (seen on a real Mac for most of a meeting): rebuilt like a
/// stalled one, but never given up on, because a headset's mute button looks the same.
@Suite struct MicrophoneZeroRecoveryTests {
    private let time = StepClock()

    @Test func rebuildsWhenOnlyZerosArrive() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy(), time: time)
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        await pass(.milliseconds(100), time, src, fed: engine)
        #expect(engine.startCount == 1)                          // 100 ms of zeros: not yet
        #expect(await reach(time, src, fed: engine) { engine.startCount == 2 && engine.isRunning })
        #expect(src.health?.restarts == 1)
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(engine.isStopped)
    }

    @Test func keepsTheEngineWhileSoundArrives() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let level = Level(); level.set(0.25)
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy(), time: time)
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: level)
        await pass(.milliseconds(700), time, src, fed: engine)
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(engine.startCount == 1)
        #expect(src.health?.restarts == 0)
    }

    /// The stall budget is for an input that is gone; zeros spend none of it and never end the source. A muted
    /// headset looks the same, so one stretch of zeros gets three rebuilds and is then left alone.
    @Test func aStretchOfZerosGetsThreeRebuildsOutsideTheBudgetAndNeverGivesUp() async throws {
        #expect(MicrophoneRecoveryPolicy.standard.maxZeroRebuilds == 3)
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let policy = zeroPolicy { $0.maxConsecutiveFailures = 1; $0.maxRebuilds = 1; $0.zeroRetryMax = .milliseconds(150) }
        let src = makeRecoveringMicSource(engine, .fake(host), policy: policy, time: time)
        let failure = FailureMessage()
        src.health?.setFailureObserver { failure.set($0) }
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        #expect(await reach(time, src, fed: engine) { engine.startCount == 4 })  // three rebuilds, past both stall budgets
        await pass(.milliseconds(900), time, src, fed: engine)                  // six more waits' worth of zeros
        #expect(engine.startCount == 4)
        #expect(src.health?.restarts == 3)
        #expect(failure.message == nil)
        #expect(engine.isRunning)
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func noZeroRebuildWhileTheRecordingIsPaused() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy(), time: time)
        try await src.start { _ in }
        src.health?.setPaused(true)
        let feeder = feed(engine, host: host, level: Level())
        await pass(.milliseconds(700), time, src, fed: engine)
        #expect(engine.startCount == 1)
        src.health?.setPaused(false)                                            // the zeros count from the resume
        await pass(.milliseconds(100), time, src, fed: engine)
        #expect(engine.startCount == 1)
        #expect(await reach(time, src, fed: engine) { engine.startCount == 2 })
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func waitsTwiceAsLongBeforeEachFurtherZeroRebuild() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy(), time: time)
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        // Rebuilds at about 0.15, 0.45 and 1.05 s into the zeros, by the source's own clock readings.
        #expect(await reach(time, src, fed: engine) { await src.zeroRebuildStarts.count == 3 })
        let starts = await src.zeroRebuildStarts
        try #require(starts.count == 3)
        #expect(starts[1] - starts[0] >= .milliseconds(300))
        #expect(starts[2] - starts[1] >= .milliseconds(600))
        #expect(await eventuallyTrue { await src.currentZeroWait == .milliseconds(1200) })   // once the third is done
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func goesBackToTheFirstWaitOnceSoundArrives() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let level = Level()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy(), time: time)
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: level)
        #expect(await reach(time, src, fed: engine) { await src.zeroRebuildStarts.count == 3 })   // and no more for this stretch
        #expect(await eventuallyTrue { await src.currentZeroWait == .milliseconds(1200) })
        level.set(0.25)
        #expect(await reach(time, src, fed: engine) { await src.currentZeroWait == .milliseconds(150) })   // heard: the first wait again
        level.set(0)
        #expect(await reach(time, src, fed: engine) { await src.zeroRebuildStarts.count == 4 })   // a new stretch: three more
        let starts = await src.zeroRebuildStarts
        #expect(starts.count >= 4 && starts[3] - starts[2] >= .milliseconds(150))
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func aPolicyWithoutAZeroTimeoutNeverRebuildsForZeros() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy { $0.zeroTimeout = nil }, time: time)
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        await pass(.milliseconds(600), time, src, fed: engine)
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(engine.startCount == 1)
    }
}
