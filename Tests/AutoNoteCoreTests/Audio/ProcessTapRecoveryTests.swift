import Testing
import Foundation
import CoreAudio
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

private final class TapChunks: Sendable {
    private let chunks = Mutex<[AudioChunk]>([])
    var all: [AudioChunk] { chunks.withLock { $0 } }
    var onBuffer: @Sendable (AudioChunk) -> Void { { chunk in self.chunks.withLock { $0.append(chunk) } } }
}

private final class Seconds: Sendable {
    private let values = Mutex<[Int]>([])
    var all: [Int] { values.withLock { $0 } }
    func add(_ s: Int) { values.withLock { $0.append(s) } }
}

/// The watchdog looks every 10 ms of wall time; every threshold is on the meeting timeline (`FakeHostClock`), at the
/// production values, so a test moves the clock instead of sleeping.
let tapRecoveryTestPolicy = SystemTapRecoveryPolicy(checkInterval: .milliseconds(10))

/// Calls the tap's IOProc with 10 ms of `value` every 5 ms of wall time, stamped with the fake clock's current time.
func feedTap(_ hw: FakeTapHardware, host: FakeHostClock, value: @escaping @Sendable () -> Float) -> Task<Void, Never> {
    Task.detached {
        var sample = 0.0
        while !Task.isCancelled {
            hw.fire(frames: 480, hostTime: host.hostTime(), sampleTime: sample, value: value())
            sample += 480
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func creations(_ hw: FakeTapHardware) -> Int { hw.calls.filter { $0 == "createTap" }.count }
private func destructions(_ hw: FakeTapHardware) -> Int { hw.calls.filter { $0 == "destroyTap" }.count }

/// True once the source has finished its `n`th rebuild (the clock may move again: the next wait starts when a
/// rebuild ends).
private func rebuilt(_ src: ProcessTapSource, _ n: Int) async -> Bool {
    await eventuallyTrue(.seconds(30)) { await src.finishedRebuilds == n }
}

/// Waits until the watchdog has looked twice more: the second look is wholly at the current clock reading (and, with
/// `fed`, after two more callbacks were drained). Also needed right after `start`: "another process has been playing
/// since" is the time of the first look that saw it. Returns early once `done`; gives up after 3 s (a rebuild under
/// way holds the looks back).
func settle(_ src: ProcessTapSource, fed: Bool = false, or done: () -> Bool = { false }) async {
    if fed {
        let drained = src.health?.callbacks ?? 0
        _ = await eventuallyTrue { done() || (src.health?.callbacks ?? 0) >= drained + 2 }
    }
    let before = await src.watchdogLooks
    _ = await eventuallyTrue {
        if done() { return true }
        return await src.watchdogLooks >= before + 2
    }
}


@Suite struct ProcessTapRecoveryTests {
    private func source(_ hw: FakeTapHardware, _ host: FakeHostClock,
                        _ tweak: (inout SystemTapRecoveryPolicy) -> Void = { _ in }) -> ProcessTapSource {
        var policy = tapRecoveryTestPolicy
        tweak(&policy)
        return ProcessTapSource(clock: .fake(host), hardware: hw, excludeBundleIDs: ["com.yutaokoshi.autonote"],
                                stopTimeout: .seconds(2), policy: policy)
    }

    @Test func rebuildsWithinFiveSecondsWhenOnlyZerosArriveWhileAnotherProcessPlays() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        defer { feeder.cancel() }
        host.advance(4.0)
        await settle(src, fed: true)
        #expect(creations(hw) == 1)                              // not yet: 4 s of zeros
        host.advance(1.1)
        #expect(await eventuallyTrue { creations(hw) == 2 })     // 5.1 s: torn down and created again
        #expect(hw.lastExcludedBundleIDs == ["com.yutaokoshi.autonote"])
        #expect(src.health?.restarts == 1)
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    /// Zeros right after the default output changed (headphones plugged in, a display's speakers): the usual moment
    /// for a tap to go deaf, so the wait is 2 s instead of 5.
    @Test func rebuildsAfterTwoSecondsOfZerosWhenTheOutputDeviceChanged() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true; hw.outputRoute = "speakers"
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)
        defer { feeder.cancel() }
        host.advance(1.0)
        await settle(src, fed: true)
        hw.outputRoute = "headphones"
        await settle(src, fed: true)                             // the change is seen at 1.0 s
        host.advance(1.5)
        await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 0)                 // 1.5 s after the change: not yet
        host.advance(0.6)
        #expect(await rebuilt(src, 1))                           // 2.1 s after it, 3.1 s into the zeros
        host.advance(4.0)
        await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 1)                 // one early rebuild per change; then the usual waits
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    /// The usual case: sound flowed until the very moment the output changed, and zeros from then on.
    @Test func rebuildsTwoSecondsAfterTheOutputDeviceChangedWhenSoundFlowedUntilThen() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true; hw.outputRoute = "speakers"
        let level = Mutex<Float>(0.25)
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { level.withLock { $0 } }
        await settle(src, fed: true)
        defer { feeder.cancel() }
        // A second at a time: a look that finds no new callback after a longer jump would take it for a stall.
        for _ in 0..<10 { host.advance(1); await settle(src, fed: true) }   // 10 s of sound
        level.withLock { $0 = 0 }; hw.outputRoute = "headphones"
        await settle(src, fed: true); await settle(src, fed: true)   // the change is seen with sound just before it
        host.advance(1.5)
        await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 0)                 // 1.5 s after the change: not yet
        host.advance(0.7)
        #expect(await rebuilt(src, 1))                           // 2.2 s after it, not 5
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    /// Zeros already past their first rebuild when the output changes: the change still gets its 2 s to settle.
    @Test func aChangeOfTheOutputDeviceDuringZerosWaitsItsTwoSecondsToo() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true; hw.outputRoute = "speakers"
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)
        defer { feeder.cancel() }
        host.advance(5.1)
        #expect(await rebuilt(src, 1))                           // the next one would be 10 s later
        host.advance(1.0)
        await settle(src, fed: true)
        hw.outputRoute = "headphones"
        await settle(src, fed: true); await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 1)                 // not at once
        host.advance(1.5)
        await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 1)                 // 1.5 s after the change: not yet
        host.advance(0.7)
        #expect(await rebuilt(src, 2))                           // 2.2 s after it
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    /// Paused: nothing is being written, so zeros are nobody's loss. No rebuild, nothing told, and the wait starts
    /// over at the resume.
    @Test func whileTheRecordingIsPausedZerosCauseNoRebuild() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let src = source(hw, host)
        let notArriving = Seconds()
        src.health?.setNotArrivingObserver { notArriving.add($0 ?? -1) }
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)
        defer { feeder.cancel() }
        host.advance(2.0)
        await settle(src, fed: true)
        src.health?.setPaused(true)
        await settle(src, fed: true)
        for _ in 0..<20 { host.advance(10); await settle(src, fed: true) }   // 200 s of zeros while paused
        #expect(await src.finishedRebuilds == 0)
        #expect(notArriving.all.isEmpty)
        src.health?.setPaused(false)
        await settle(src, fed: true)
        host.advance(4.0)
        await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 0)                 // 4 s after the resume: not yet
        host.advance(1.1)
        #expect(await rebuilt(src, 1))
        await src.stop()
    }

    /// Plain silence: nobody plays, so zeros (or no callbacks at all, as an idle tap delivers) are what is expected.
    @Test func doesNotRebuildWhileNobodyPlays() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = false
        let src = source(hw, host)
        let failure = FailureMessage()
        src.health?.setFailureObserver { failure.set($0) }
        try await src.start { _ in }
        await settle(src)
        for _ in 0..<10 { host.advance(30); await settle(src) }     // 5 minutes without one callback
        #expect(creations(hw) == 1)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        for _ in 0..<10 { host.advance(30); await settle(src, fed: true) }   // 5 minutes of zeros
        feeder.cancel(); await feeder.value
        #expect(creations(hw) == 1)
        #expect(failure.message == nil)
        #expect(src.health?.restarts == 0)
        await src.stop()
    }

    @Test func anUnknownAnswerAboutOtherProcessesNeverRebuilds() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = nil
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        for _ in 0..<5 { host.advance(30); await settle(src, fed: true) }
        feeder.cancel(); await feeder.value
        #expect(creations(hw) == 1)
        await src.stop()
    }

    @Test func keepsTheTapWhileAudioFlows() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0.25 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        for _ in 0..<20 { host.advance(3); await settle(src, fed: true) }
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(creations(hw) == 1)
        #expect(src.health?.restarts == 0)
    }

    @Test func theZeroRebuildIntervalDoublesAndGoesBackToFiveSecondsOnceAudioReturns() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let level = Mutex<Float>(0)
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { level.withLock { $0 } }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        defer { feeder.cancel() }
        host.advance(5.1)
        #expect(await rebuilt(src, 1))                           // first rebuild after 5 s
        host.advance(5.1)
        await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 1)                 // the next one waits 10 s
        host.advance(5.0)
        #expect(await rebuilt(src, 2))
        host.advance(10.1)
        await settle(src, fed: true)
        #expect(await src.finishedRebuilds == 2)                 // then 20 s

        level.withLock { $0 = 0.25 }                             // audio is back on the rebuilt tap
        #expect(await eventuallyTrue { (src.health?.nonZeroCallbacks ?? 0) > 0 })
        await settle(src)
        level.withLock { $0 = 0 }
        let fired = await src.statistics().callbacks
        #expect(await eventuallyTrue { (src.health?.callbacks ?? 0) >= fired + 2 })   // the non-zero ones are all drained
        await settle(src)                                        // and seen at this time
        host.advance(5.1)
        #expect(await rebuilt(src, 3))                           // back to 5 s
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    /// Zeros may be plain silence from an app that keeps its output open: rebuilding for them never ends the source.
    @Test func zeroRebuildsNeverGiveUpAndTellTheOwnerOnceAfterAMinute() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let src = source(hw, host) { $0.maxRebuilds = 2; $0.maxConsecutiveFailures = 1 }
        let failure = FailureMessage(); let notArriving = Seconds()
        src.health?.setFailureObserver { failure.set($0) }
        src.health?.setNotArrivingObserver { notArriving.add($0 ?? -1) }
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        defer { feeder.cancel() }
        host.advance(5.1)
        #expect(await eventuallyTrue { creations(hw) == 2 })
        #expect(notArriving.all.isEmpty)                         // 5 s is not a minute
        for _ in 0..<40 { host.advance(10); await settle(src, fed: true) }   // 400 s of zeros
        #expect(creations(hw) >= 6)
        #expect(failure.message == nil)
        #expect(notArriving.all.count == 1)
        #expect((notArriving.all.first ?? 0) >= 60)
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    /// Told once per stretch: when sound is heard again the owner learns it, and a later minute of zeros is told again.
    @Test func tellsTheOwnerWhenAudioIsBackAndAgainForALaterStretch() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let level = Mutex<Float>(0)
        let src = source(hw, host)
        let told = Seconds()
        src.health?.setNotArrivingObserver { told.add($0 ?? -1) }       // -1: arriving again
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { level.withLock { $0 } }
        await settle(src, fed: true)
        defer { feeder.cancel() }
        for _ in 0..<70 { host.advance(1); await settle(src, fed: true) }    // 70 s of zeros
        #expect(told.all.count == 1 && (told.all.first ?? 0) >= 60)
        level.withLock { $0 = 0.25 }
        #expect(await eventuallyTrue(.seconds(10)) { told.all.last == -1 })   // heard again
        #expect(told.all.count == 2)
        level.withLock { $0 = 0 }
        let fired = await src.statistics().callbacks
        #expect(await eventuallyTrue(.seconds(10)) { (src.health?.callbacks ?? 0) >= fired + 2 })
        await settle(src)
        for _ in 0..<70 { host.advance(1); await settle(src, fed: true) }    // another 70 s of zeros
        #expect(told.all.count == 3 && (told.all.last ?? 0) >= 60)
        await src.stop()
    }

    @Test func rebuildsWhenCallbacksStopWhileAnotherProcessPlays() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let out = TapChunks()
        let src = source(hw, host)
        try await src.start(onBuffer: out.onBuffer)
        await settle(src)
        hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: 0), sampleTime: 0, value: 0.25)
        await settle(src)                                           // the watchdog saw the callback at 0 s
        host.advance(1.5)
        await settle(src)
        #expect(creations(hw) == 1)                              // 1.5 s without a callback is not a stall yet
        host.advance(0.6)
        #expect(await eventuallyTrue { hw.calls.filter { $0 == "start" }.count == 2 })   // the new IOProc runs
        #expect(creations(hw) == 2)
        // The rebuilt tap delivers; its chunks keep their place on the timeline (host time 10 s).
        for i in 0..<100 {
            hw.fire(frames: 480, hostTime: host.hostTime(atSeconds: 10.0 + Double(i) * 0.01), sampleTime: Double(i * 480), value: 0.25)
        }
        await src.stop()
        let late = try #require(out.all.first { $0.start.seconds >= 5 })
        #expect(abs(late.start.seconds - 10.0) <= 0.02)
        #expect(src.health?.restarts == 1)
        let stats = await src.statistics()
        #expect(stats.callbacks == 101)                          // counted across the rebuild
    }

    @Test func givesUpAndReportsOnceWhenRebuildsDoNotBringCallbacksBack() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let src = source(hw, host) { $0.maxConsecutiveFailures = 3 }
        let failure = FailureMessage()
        src.health?.setFailureObserver { failure.set($0) }
        try await src.start { _ in }
        await settle(src)
        var steps = 0
        while failure.message == nil, steps < 60 { host.advance(3); await settle(src, or: { failure.message != nil }); steps += 1 }
        #expect(failure.message?.contains("3 rebuild(s)") == true)
        #expect(creations(hw) == 4)                              // the start plus three rebuilds
        let after = creations(hw)
        for _ in 0..<5 { host.advance(30); await settle(src) }
        #expect(creations(hw) == after)                          // no more attempts after giving up
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    /// A rebuild that cannot create the tap is a failure of the track, whoever is or is not playing.
    @Test func aRebuildThatCannotBringTheTapUpEndsInAFailure() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let src = source(hw, host) { $0.maxConsecutiveFailures = 2 }
        let failure = FailureMessage()
        src.health?.setFailureObserver { failure.set($0) }
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        defer { feeder.cancel() }
        hw.failOn = "createAggregate"
        hw.othersPlaying = true
        host.advance(5.1)                                        // a zero rebuild tears the tap down; bring-up fails
        var steps = 0
        while failure.message == nil, steps < 60 { host.advance(3); await settle(src, or: { failure.message != nil }); steps += 1 }
        #expect(failure.message != nil)
        await src.stop()
        #expect(creations(hw) == destructions(hw))
    }

    @Test func stopDuringARebuildTearsDownWhatTheRebuildBroughtUp() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = true
        let src = source(hw, host)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        hw.startDelay = .milliseconds(300)                       // the rebuild's bring-up takes a while
        host.advance(5.1)
        #expect(await eventuallyTrue { creations(hw) == 2 })
        await src.stop()                                         // lands while `start` of the new tap is blocked
        feeder.cancel(); await feeder.value
        let settled = creations(hw)
        try await Task.sleep(for: .milliseconds(500))
        #expect(creations(hw) == settled)                        // nothing comes up after the stop
        #expect(creations(hw) == destructions(hw))
        #expect(hw.calls.suffix(1) == ["destroyTap"])
    }

    @Test func countsSuspectSecondsOnlyWhileAnotherProcessPlays() async throws {
        let host = FakeHostClock(); let hw = FakeTapHardware(); hw.othersPlaying = false
        let clock = MeetingClock.fake(host)
        let src = ProcessTapSource(clock: clock, hardware: hw, policy: tapRecoveryTestPolicy)
        try await src.start { _ in }
        await settle(src)
        let feeder = feedTap(hw, host: host) { 0 }
        await settle(src, fed: true)                             // callbacks flow before the clock moves
        for _ in 0..<20 { host.advance(1); await settle(src, fed: true) }   // 20 s of zeros, nobody plays
        hw.othersPlaying = true
        await settle(src)
        for _ in 0..<20 { host.advance(1); await settle(src, fed: true) }   // 20 s of zeros while playing
        feeder.cancel(); await feeder.value
        let end = clock.now().seconds
        await src.stop()
        let health = try #require(src.health)
        let s = SourceHealth.summary(track: .system, sources: [health], endSeconds: end)
        #expect(s.zeroSeconds >= 35)
        let suspect = try #require(s.suspectZeroSeconds)
        #expect(suspect >= 15 && suspect <= 21)                  // the second 20 s, not the first
        #expect((s.suspectNoCallbackSeconds ?? -1) >= 0 && (s.suspectNoCallbackSeconds ?? 99) <= 2)
        #expect(s.droppedFrames == 0)
    }
}
