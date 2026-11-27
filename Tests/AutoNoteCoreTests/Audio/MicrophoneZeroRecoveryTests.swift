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

/// Pushes 50 ms of input at `level` every 20 ms of wall time, advancing host time, until cancelled.
private func feed(_ engine: FakeMicrophoneEngine, host: FakeHostClock, level: Level) -> Task<Void, Never> {
    Task.detached {
        var t = 0.0
        while !Task.isCancelled {
            let frames = Int(engine.format.sampleRate * 0.05)
            engine.push(frames: frames, hostTime: host.hostTime(atSeconds: t), value: level.current)
            t += 0.05
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// The microphone's zero watch in short: a rebuild after 150 ms of exact zeros, then waits of 300 and 600 ms; three
/// rebuilds per stretch of zeros, as in production.
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
    @Test func rebuildsWhenOnlyZerosArrive() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy())
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        #expect(await eventuallyTrue { engine.startCount >= 2 && engine.isRunning })
        #expect((src.health?.restarts ?? 0) >= 1)
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(engine.isStopped)
    }

    @Test func keepsTheEngineWhileSoundArrives() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let level = Level(); level.set(0.25)
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy())
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: level)
        try await Task.sleep(for: .milliseconds(700))
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
        let src = makeRecoveringMicSource(engine, .fake(host), policy: policy)
        let failure = FailureMessage()
        src.health?.setFailureObserver { failure.set($0) }
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        #expect(await eventuallyTrue(.seconds(5)) { engine.startCount == 4 })   // three rebuilds, past both stall budgets
        try await Task.sleep(for: .milliseconds(900))                           // six more waits' worth of zeros
        #expect(engine.startCount == 4)
        #expect(src.health?.restarts == 3)
        #expect(failure.message == nil)
        #expect(engine.isRunning)
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func noZeroRebuildWhileTheRecordingIsPaused() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy())
        try await src.start { _ in }
        src.health?.setPaused(true)
        let feeder = feed(engine, host: host, level: Level())
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.startCount == 1)
        src.health?.setPaused(false)                                            // the zeros count from the resume
        #expect(await eventuallyTrue { engine.startCount == 2 })
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func waitsTwiceAsLongBeforeEachFurtherZeroRebuild() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy())
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        try await Task.sleep(for: .milliseconds(1500))   // rebuilds at about 0.15, 0.45 and 1.05 s; every 0.15 s would be 9
        let restarts = src.health?.restarts ?? 0
        #expect(restarts >= 1 && restarts <= 4)
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func goesBackToTheFirstWaitOnceSoundArrives() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let level = Level()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy())
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: level)
        #expect(await eventuallyTrue(.seconds(5)) { (src.health?.restarts ?? 0) == 3 })   // and no more for this stretch
        level.set(0.25)
        let heard = src.health?.nonZeroCallbacks ?? 0
        #expect(await eventuallyTrue { (src.health?.nonZeroCallbacks ?? 0) > heard })
        try await Task.sleep(for: .milliseconds(100))    // a few looks of the watchdog see it
        let before = src.health?.restarts ?? 0
        level.set(0)
        #expect(await eventuallyTrue(.milliseconds(1200)) { (src.health?.restarts ?? 0) > before })   // a new stretch: 0.15 s, three more
        feeder.cancel(); await feeder.value
        await src.stop()
    }

    @Test func aPolicyWithoutAZeroTimeoutNeverRebuildsForZeros() async throws {
        let host = FakeHostClock(); let engine = FakeMicrophoneEngine()
        let src = makeRecoveringMicSource(engine, .fake(host), policy: zeroPolicy { $0.zeroTimeout = nil })
        try await src.start { _ in }
        let feeder = feed(engine, host: host, level: Level())
        try await Task.sleep(for: .milliseconds(600))
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(engine.startCount == 1)
    }
}
