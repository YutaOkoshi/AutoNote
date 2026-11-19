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

final class FailureMessage: Sendable {
    private let value = Mutex<String?>(nil)
    var message: String? { value.withLock { $0 } }
    func set(_ m: String) { value.withLock { $0 = m } }
}

let micRecoveryTestPolicy = MicrophoneRecoveryPolicy(checkInterval: .milliseconds(20), settleDelay: .milliseconds(30),
                                            stallTimeout: .milliseconds(600), retryDelay: .milliseconds(30),
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
func feed(_ engine: FakeMicrophoneEngine, host: FakeHostClock, from: Double) -> Task<Void, Never> {
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
        try await Task.sleep(for: .milliseconds(1_000))   // well past stallTimeout
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

    @Test func oneStopSeenTwiceRebuildsOnceEvenIfTheFirstCallbackIsSlow() async throws {
        // The engine stops itself and also posts the configuration change; after the rebuild, the first callback
        // takes longer than the settle delay (as right after an A2DP → HFP switch) but less than stallTimeout.
        // The notification lands after the watchdog has already seen the stopped engine and rebuilt.
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1; engine.notificationDelay = 0.08
        let src = makeRecoveringMicSource(engine, .fake())
        try await src.start { _ in }
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        try await Task.sleep(for: .milliseconds(300))
        await src.stop()
        #expect(engine.startCount == 2)
        #expect(src.health?.restarts == 1)
    }

    @Test func aFormatChangeDuringTheBackOffIsNotDropped() async throws {
        var policy = micRecoveryTestPolicy
        policy.retryDelay = .milliseconds(500)   // the first rebuild leaves 0.5 s of back-off
        let host = FakeHostClock()
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1
        let src = makeRecoveringMicSource(engine, .fake(host), policy: policy)
        try await src.start { _ in }
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        let feeder = feed(engine, host: host, from: 1)   // callbacks keep flowing: only the format tells
        engine.simulateConfigurationChange(stopEngine: false, newFormat: InputFormat(sampleRate: 16_000, channels: 1))
        let rebuilt = await eventuallyTrue { engine.startCount == 3 }
        feeder.cancel(); await feeder.value
        await src.stop()
        #expect(rebuilt)
        #expect(src.health?.restarts == 2)
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

/// The Bluetooth input is held open (`MicrophoneInputHolding`) so the headset stays on HFP while the engine is rebuilt.
@Suite struct MicrophoneInputHoldTests {
    private func source(_ engine: FakeMicrophoneEngine, _ clock: MeetingClock, _ hold: FakeMicrophoneInputHold,
                        settleTimeout: Duration = .seconds(1)) -> MicrophoneSource {
        var policy = micRecoveryTestPolicy
        policy.holdSettle = .milliseconds(100)
        policy.holdSettleTimeout = settleTimeout
        return MicrophoneSource(deviceUID: nil, clock: clock, permission: FakeMicrophonePermission(.authorized), engine: engine,
                                lookup: FakeDeviceLookup(), policy: policy, inputHold: hold)
    }

    @Test func holdsTheInputForTheWholeRecordingAcrossRebuilds() async throws {
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1
        let hold = FakeMicrophoneInputHold()
        let src = source(engine, .fake(), hold)
        try await src.start { _ in }
        #expect(hold.holdCount == 1)
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        #expect(hold.isHeld)
        #expect(hold.holdCount == 1)
        #expect(hold.releaseCount == 0)
        await src.stop()
        #expect(!hold.isHeld)
        #expect(hold.releaseCount == 1)
    }

    @Test func aRebuildWaitsUntilTheHeldInputIsSteady() async throws {
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1
        let hold = FakeMicrophoneInputHold(steady: false)
        let src = source(engine, .fake(), hold)
        try await src.start { _ in }
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.startCount == 1)   // stopped itself; the rebuild waits for the headset to settle
        hold.steady = true
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        await src.stop()
    }

    @Test func aRebuildGoesOnWhenTheHeldInputNeverSettles() async throws {
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1
        let hold = FakeMicrophoneInputHold(steady: false)
        let src = source(engine, .fake(), hold, settleTimeout: .milliseconds(200))
        try await src.start { _ in }
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        await src.stop()
        #expect(hold.releaseCount == 1)
    }

    @Test func aFailedStartReleasesTheHold() async throws {
        let engine = FakeMicrophoneEngine(); engine.failPrepare(1, with: AudioSourceError.unsupportedFormat)
        let hold = FakeMicrophoneInputHold()
        let src = source(engine, .fake(), hold)
        await #expect(throws: (any Error).self) { try await src.start { _ in } }
        #expect(hold.holdCount == 1)
        #expect(!hold.isHeld)
    }

    @Test func givingUpReleasesTheHold() async throws {
        let engine = FakeMicrophoneEngine()   // never pushes: every rebuild stalls
        let hold = FakeMicrophoneInputHold()
        let src = source(engine, .fake(), hold)
        try await src.start { _ in }
        #expect(await eventuallyTrue(.seconds(8)) { !hold.isHeld })
        #expect(hold.releaseCount == 1)
        await src.stop()
        #expect(hold.releaseCount == 1)
    }
}

/// REVIEW.md follow-ups on the recovery loop (L1, L6, L7, M2).
@Suite struct MicrophoneRecoveryReviewTests {
    private func source(_ engine: FakeMicrophoneEngine, _ clock: MeetingClock, hold: FakeMicrophoneInputHold? = nil,
                        _ tweak: (inout MicrophoneRecoveryPolicy) -> Void = { _ in }) -> MicrophoneSource {
        var policy = micRecoveryTestPolicy
        policy.holdSettle = .milliseconds(20)
        policy.holdSettleTimeout = .milliseconds(200)
        tweak(&policy)
        return MicrophoneSource(deviceUID: nil, clock: clock, permission: FakeMicrophonePermission(.authorized), engine: engine,
                                lookup: FakeDeviceLookup(), policy: policy, inputHold: hold ?? FakeMicrophoneInputHold(steady: true))
    }

    /// L1: `stop()` while a check waits on the engine; the check must not give up (and report) afterwards.
    @Test func stopDuringAPausedCheckNeitherGivesUpNorReports() async throws {
        let engine = FakeMicrophoneEngine()   // never pushes: every start stalls
        let src = source(engine, .fake()) { $0.maxConsecutiveFailures = 1; $0.stallTimeout = .seconds(5) }
        let failure = FailureMessage()
        try await src.start { _ in }
        src.health?.setFailureObserver { failure.set($0) }
        engine.simulateConfigurationChange(stopEngine: true)
        #expect(await eventuallyTrue { engine.startCount == 2 })        // rebuild #1: consecutive failures = 1
        engine.currentFormatDelay = 0.4                                // the next check pauses in currentFormat
        engine.simulateConfigurationChange(stopEngine: true)           // …with a reason to give up when it resumes
        try await Task.sleep(for: .milliseconds(150))
        await src.stop()
        try await Task.sleep(for: .milliseconds(600))
        #expect(failure.message == nil)
        #expect(engine.isStopped)
    }

    /// L6: callbacks flowing long enough after a rebuild give the rebuild budget back.
    @Test func theRebuildBudgetComesBackAfterHealthyRunning() async throws {
        let host = FakeHostClock(); let clock = MeetingClock.fake(host)
        let engine = FakeMicrophoneEngine()
        let src = source(engine, clock) { $0.maxRebuilds = 2; $0.rebuildBudgetReset = .milliseconds(250) }
        let failure = FailureMessage()
        try await src.start { _ in }
        src.health?.setFailureObserver { failure.set($0) }
        let feeder = feed(engine, host: host, from: 0)
        defer { feeder.cancel() }
        for round in 1...4 {
            try await Task.sleep(for: .milliseconds(450))
            engine.simulateConfigurationChange(stopEngine: true)
            #expect(await eventuallyTrue { engine.startCount == round + 1 && engine.isRunning })
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(failure.message == nil)
        #expect(await src.rebuildCount == 4)
        await src.stop()
    }

    /// L6: without that healthy stretch the budget still ends the recovery (and reports once).
    @Test func theRebuildBudgetRunsOutWithoutHealthyRunning() async throws {
        let host = FakeHostClock(); let clock = MeetingClock.fake(host)
        let engine = FakeMicrophoneEngine()
        let src = source(engine, clock) { $0.maxRebuilds = 2; $0.rebuildBudgetReset = .seconds(30) }
        let failure = FailureMessage()
        try await src.start { _ in }
        src.health?.setFailureObserver { failure.set($0) }
        let feeder = feed(engine, host: host, from: 0)
        defer { feeder.cancel() }
        for _ in 1...3 {
            try await Task.sleep(for: .milliseconds(150))
            engine.simulateConfigurationChange(stopEngine: true)
        }
        #expect(await eventuallyTrue { failure.message != nil })
        #expect(engine.startCount == 3)
        await src.stop()
    }

    /// M2: the engine reads a device that is no longer the one to read; same format, still running.
    @Test func aStaleDeviceIsRebuiltAfterAConfigurationChange() async throws {
        let host = FakeHostClock(); let clock = MeetingClock.fake(host)
        let engine = FakeMicrophoneEngine()
        let src = source(engine, clock)
        try await src.start { _ in }
        let feeder = feed(engine, host: host, from: 0)
        defer { feeder.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        engine.needsRebuild = true
        engine.simulateConfigurationChange(stopEngine: false)
        #expect(await eventuallyTrue { engine.startCount == 2 })
        await src.stop()
    }

    /// M2: also when the notification was missed.
    @Test func aStaleDeviceIsRebuiltWithoutANotification() async throws {
        let host = FakeHostClock(); let clock = MeetingClock.fake(host)
        let engine = FakeMicrophoneEngine()
        let src = source(engine, clock)
        try await src.start { _ in }
        let feeder = feed(engine, host: host, from: 0)
        defer { feeder.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        engine.needsRebuild = true
        #expect(await eventuallyTrue { engine.startCount == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.startCount == 2)   // cleared by the rebuild's prepare: no loop
        await src.stop()
    }

    /// M2 / L7: a rebuild holds the input again when the held device is no longer the one (new default, new ID).
    @Test func aRebuildHoldsAgainWhenTheHeldDeviceWasReplaced() async throws {
        let engine = FakeMicrophoneEngine()
        let hold = FakeMicrophoneInputHold()
        let src = source(engine, .fake(), hold: hold)
        try await src.start { _ in }
        #expect(hold.holdCount == 1)
        hold.current = false   // the device went away and came back with a new ID
        engine.simulateConfigurationChange(stopEngine: true)
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        #expect(hold.holdCount == 2)
        #expect(hold.isHeld)
        await src.stop()
        #expect(!hold.isHeld)
    }

    /// M2: the new default input is not Bluetooth: the rebuild lets the headset go (no HFP for the rest of the meeting).
    @Test func aRebuildReleasesTheHoldWhenTheNewInputIsNotBluetooth() async throws {
        let engine = FakeMicrophoneEngine()
        let hold = FakeMicrophoneInputHold()
        let src = source(engine, .fake(), hold: hold)
        try await src.start { _ in }
        #expect(hold.isHeld)
        hold.current = false        // default input switched to the built-in microphone
        hold.holdsBluetooth = false
        engine.needsRebuild = true
        engine.simulateConfigurationChange(stopEngine: false)
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        #expect(!hold.isHeld)
        #expect(hold.releaseCount == 1)
        await src.stop()
        #expect(hold.releaseCount == 1)
    }

    /// The held device stays the same: no second hold (HFP must not drop during a rebuild).
    @Test func aRebuildKeepsTheHoldOfTheSameDevice() async throws {
        let engine = FakeMicrophoneEngine(); engine.stopItselfOnStarts = 1
        let hold = FakeMicrophoneInputHold()
        let src = source(engine, .fake(), hold: hold)
        try await src.start { _ in }
        #expect(await eventuallyTrue { engine.startCount == 2 && engine.isRunning })
        #expect(hold.holdCount == 1 && hold.releaseCount == 0)
        await src.stop()
    }
}
