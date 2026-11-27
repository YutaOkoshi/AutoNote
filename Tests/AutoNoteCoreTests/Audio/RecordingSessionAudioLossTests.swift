import Testing
import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

/// A real `ProcessTapSource` on fake tap hardware inside a real `RecordingSession`; the microphone is a plain fake.
private final class TapSourceFactory: AudioSourceFactory, @unchecked Sendable {
    let hardware = FakeTapHardware()
    let mic = FakeAudioSource(track: .mic)
    private let policy: SystemTapRecoveryPolicy
    private let made = Mutex<ProcessTapSource?>(nil)
    init(policy: SystemTapRecoveryPolicy = tapRecoveryTestPolicy) { self.policy = policy }
    var tap: ProcessTapSource? { made.withLock { $0 } }
    func makeSystemSource(clock: MeetingClock) -> any AudioSource {
        let source = ProcessTapSource(clock: clock, hardware: hardware, stopTimeout: .seconds(2), policy: policy)
        made.withLock { $0 = source }
        return source
    }
    func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource { mic }
    func inputDevice(uid: String?) -> DeviceRef? { FakeAudioSourceFactory.defaultInput }
}

private struct TapSession {
    let session: RecordingSession
    let manifests: ManifestStore
    let factory: TapSourceFactory
    let host = FakeHostClock()

    init(policy: SystemTapRecoveryPolicy = tapRecoveryTestPolicy) throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        manifests = ManifestStore(paths: paths)
        factory = TapSourceFactory(policy: policy)
        session = RecordingSession(paths: paths, manifests: manifests, sources: factory, host: host, disk: FakeDiskSpace(),
                                   now: { Samples.start }, tickInterval: .seconds(3600), timeZone: Samples.tokyo)
    }
}

/// What a recording said about system audio so far, in order.
private final class SystemAudioLog: Sendable {
    private let said = Mutex<[String]>([])
    var all: [String] { said.withLock { $0 } }
    func collect(_ events: AsyncStream<RecordingEvent>) -> Task<Void, Never> {
        Task {
            for await event in events {
                let word: String? = switch event {
                case .audioNotArriving(.system, _): "notArriving"
                case .audioArrivingAgain(.system): "again"
                case .silenceWarning(let w) where w.track == .system: "silence"
                default: nil
                }
                if let word { said.withLock { $0.append(word) } }
                if case .stopped = event { break }
            }
        }
    }
}

private func notArriving(_ events: [RecordingEvent]) -> [Int] {
    events.compactMap { if case .audioNotArriving(.system, let seconds) = $0 { seconds } else { nil } }
}

private func failed(_ events: [RecordingEvent], _ track: Track) -> Bool {
    events.contains { if case .sourceFailed(track, _) = $0 { true } else { false } }
}

/// What the recording says afterwards about system audio that did not arrive (`manifest.audio_loss`), and what it
/// must not say about plain silence.
@Suite struct RecordingSessionAudioLossTests {
    /// Another app plays the whole time, the tap calls back, every sample is exactly zero.
    @Test func systemAudioThatStaysZeroWhileAnotherProcessPlaysIsALoss() async throws {
        let t = try TapSession(); t.factory.hardware.othersPlaying = true
        let events = await t.session.events()
        _ = try await t.session.start(.init(language: .ja))
        let tap = try #require(t.factory.tap)
        await settle(tap)
        let feeder = feedTap(t.factory.hardware, host: t.host) { 0 }
        await settle(tap, fed: true)
        for _ in 0..<90 { t.host.advance(1); await settle(tap, fed: true) }
        feeder.cancel(); await feeder.value
        let m = try await t.session.stop()

        let system = try #require(m.audioHealth?.first { $0.track == .system })
        #expect((system.suspectZeroSeconds ?? 0) >= 75)
        #expect(system.restarts >= 3)                       // 5 s, then 10, 20, 40 s later
        #expect(system.droppedFrames == 0)
        let loss = try #require(m.audioLoss)
        #expect(loss.count == 1 && loss.first?.track == .system && loss.first?.sourceFailed == false)
        #expect((loss.first?.seconds ?? 0) >= 75 && (loss.first?.seconds ?? 0) <= 91)
        let received = await eventsUntilStopped(events)
        #expect(notArriving(received).count == 1)           // told once while recording
        #expect((notArriving(received).first ?? 0) >= 60)
        #expect(!failed(received, .system))                 // zeros never fail the track
        #expect(try await t.manifests.load(m.id) == m)
    }

    /// An in-person meeting: nobody plays audio, so the tap never calls back for the whole hour.
    @Test func aMeetingWithoutSystemAudioIsNotALoss() async throws {
        let t = try TapSession(); t.factory.hardware.othersPlaying = false
        let events = await t.session.events()
        _ = try await t.session.start(.init(language: .ja))
        let tap = try #require(t.factory.tap)
        await settle(tap)
        for _ in 0..<60 { t.host.advance(60); await settle(tap) }
        let m = try await t.session.stop()

        let system = try #require(m.audioHealth?.first { $0.track == .system })
        #expect(system.noCallbackSeconds == 3600)           // counted as before…
        #expect(system.suspectNoCallbackSeconds == 0 && system.suspectZeroSeconds == 0)   // …but nobody was playing
        #expect(system.restarts == 0)
        #expect(m.audioLoss == nil)
        let received = await eventsUntilStopped(events)
        #expect(notArriving(received).isEmpty && !failed(received, .system))
    }

    /// The same hour, but the other app's audio was heard for a moment and then it kept its output open in silence
    /// for a while (a pause): well below a tenth of the meeting, so not a loss.
    @Test func aShortStretchOfZerosInALongMeetingIsNotALoss() async throws {
        let t = try TapSession(); t.factory.hardware.othersPlaying = true
        let level = Mutex<Float>(0.25)
        _ = try await t.session.start(.init(language: .ja))
        let tap = try #require(t.factory.tap)
        await settle(tap)
        let feeder = feedTap(t.factory.hardware, host: t.host) { level.withLock { $0 } }
        await settle(tap, fed: true)
        for _ in 0..<20 { t.host.advance(1); await settle(tap, fed: true) }      // 20 s of sound
        level.withLock { $0 = 0 }
        for _ in 0..<20 { t.host.advance(1); await settle(tap, fed: true) }      // 20 s of zeros while "playing"
        t.factory.hardware.othersPlaying = false
        await settle(tap, fed: true)
        for _ in 0..<26 { t.host.advance(10); await settle(tap, fed: true) }     // the rest: silence, nobody plays
        feeder.cancel(); await feeder.value
        let m = try await t.session.stop()

        let system = try #require(m.audioHealth?.first { $0.track == .system })
        #expect((system.suspectZeroSeconds ?? 0) >= 15 && (system.suspectZeroSeconds ?? 0) <= 22)
        #expect(m.audioLoss == nil)                         // 20 s of 300 s: below max(30 s, 10 %)
    }

    /// Paused for most of the meeting while another app went on playing into a tap that delivered zeros: nothing
    /// was being recorded then, so it is neither rebuilt for, nor told, nor a loss.
    @Test func zerosWhileTheRecordingIsPausedAreNotALoss() async throws {
        let t = try TapSession(); t.factory.hardware.othersPlaying = true
        let level = Mutex<Float>(0.25)
        let events = await t.session.events()
        _ = try await t.session.start(.init(language: .ja))
        let tap = try #require(t.factory.tap)
        await settle(tap)
        let feeder = feedTap(t.factory.hardware, host: t.host) { level.withLock { $0 } }
        await settle(tap, fed: true)
        for _ in 0..<20 { t.host.advance(1); await settle(tap, fed: true) }      // 20 s of sound
        try await t.session.pause()
        level.withLock { $0 = 0 }
        for _ in 0..<100 { t.host.advance(1); await settle(tap, fed: true) }     // 100 s of zeros, paused
        level.withLock { $0 = 0.25 }
        await settle(tap, fed: true)
        try await t.session.resume()
        for _ in 0..<20 { t.host.advance(1); await settle(tap, fed: true) }      // 20 s of sound
        feeder.cancel(); await feeder.value
        let m = try await t.session.stop()

        let system = try #require(m.audioHealth?.first { $0.track == .system })
        #expect(system.zeroSeconds >= 95)                   // counted as before
        #expect((system.suspectZeroSeconds ?? 99) <= 2)     // only the seconds the pause began and ended in
        #expect(system.restarts == 0)
        #expect(m.audioLoss == nil)
        #expect(notArriving(await eventsUntilStopped(events)).isEmpty)
    }

    /// One notice about system audio at a time: once "not arriving" is told, the general silence warning (60 s
    /// without a non-zero sample) stays away; the manifest still carries the silence flag. When sound is heard again
    /// the listeners learn it, and a later minute of zeros is told again.
    @Test func notArrivingStandsInForTheSilenceWarningAndIsTakenBackWhenAudioReturns() async throws {
        let t = try TapSession(); t.factory.hardware.othersPlaying = true
        let level = Mutex<Float>(0)
        let log = SystemAudioLog()
        let collector = log.collect(await t.session.events())
        _ = try await t.session.start(.init(language: .ja))
        let tap = try #require(t.factory.tap)
        await settle(tap)
        let feeder = feedTap(t.factory.hardware, host: t.host) { level.withLock { $0 } }
        await settle(tap, fed: true)
        for _ in 0..<70 { t.host.advance(1); await settle(tap, fed: true) }      // 70 s of zeros
        #expect(await eventuallyTrue(.seconds(30)) { log.all == ["notArriving"] })
        await t.session.tick()                                                   // 70 s without a non-zero sample
        level.withLock { $0 = 0.25 }
        #expect(await eventuallyTrue(.seconds(30)) { log.all == ["notArriving", "again"] })
        level.withLock { $0 = 0 }
        let fired = await tap.statistics().callbacks
        #expect(await eventuallyTrue(.seconds(10)) { (tap.health?.callbacks ?? 0) >= fired + 2 })
        await settle(tap)
        for _ in 0..<70 { t.host.advance(1); await settle(tap, fed: true) }      // and another 70 s
        #expect(await eventuallyTrue(.seconds(30)) { log.all.count == 3 })
        feeder.cancel(); await feeder.value
        let m = try await t.session.stop()
        await collector.value
        #expect(log.all == ["notArriving", "again", "notArriving"])
        #expect(m.silenceWarning)
    }

    /// Another app plays and the tap does not call back at all; rebuilding does not help.
    @Test func aTapThatNeverCallsBackWhileAnotherProcessPlaysFailsTheTrack() async throws {
        var policy = tapRecoveryTestPolicy
        policy.maxConsecutiveFailures = 2
        let t = try TapSession(policy: policy); t.factory.hardware.othersPlaying = true
        let events = await t.session.events()
        _ = try await t.session.start(.init(language: .ja))
        let tap = try #require(t.factory.tap)
        await settle(tap)
        for _ in 0..<30 { t.host.advance(1); await settle(tap) }   // rebuilds at 2 s and 4 s, gives up at 6 s
        try await Task.sleep(for: .milliseconds(100))       // the give-up reaches the session
        let m = try await t.session.stop()

        let loss = try #require(m.audioLoss)
        #expect(loss.count == 1 && loss.first?.track == .system && loss.first?.sourceFailed == true)
        #expect((loss.first?.seconds ?? 0) >= 20)
        #expect(m.silenceWarning)
        let received = await eventsUntilStopped(events)
        #expect(failed(received, .system))
        #expect(notArriving(received).isEmpty)              // the failure is the message; not both
    }
}
