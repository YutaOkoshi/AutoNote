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
                case .audioNotArriving(.system, _, let heardBefore): heardBefore ? "notArriving" : "nothingArrived"
                case .sourceFailed(.system, _): "failed"
                case .sourceRecovered(.system): "recovered"
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
    events.compactMap { if case .audioNotArriving(.system, let seconds, _) = $0 { seconds } else { nil } }
}

private func failed(_ events: [RecordingEvent], _ track: Track) -> Bool {
    events.contains { if case .sourceFailed(track, _) = $0 { true } else { false } }
}

/// What the recording says afterwards about system audio that did not arrive (`manifest.audio_loss`), and what it
/// must not say about plain silence.
@Suite(.timeLimit(.minutes(10))) struct RecordingSessionAudioLossTests {
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
        // Not one sample was heard in this recording, which is said too (the permission is then in doubt as well).
        #expect(received.contains { if case .audioNotArriving(.system, _, heardBefore: false) = $0 { true } else { false } })
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
        #expect(await soon { log.all == ["nothingArrived"] })    // not one sample so far
        await t.session.tick()                                                   // 70 s without a non-zero sample
        level.withLock { $0 = 0.25 }
        #expect(await soon { log.all == ["nothingArrived", "again"] })
        level.withLock { $0 = 0 }
        let fired = await tap.statistics().callbacks
        #expect(await soon { (tap.health?.callbacks ?? 0) >= fired + 2 })
        await settle(tap)
        for _ in 0..<70 { t.host.advance(1); await settle(tap, fed: true) }      // and another 70 s
        #expect(await soon { log.all.count == 3 })
        feeder.cancel(); await feeder.value
        let m = try await t.session.stop()
        await collector.value
        #expect(log.all == ["nothingArrived", "again", "notArriving"])                   // heard before: said so
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

    /// The tap was given up on (no callbacks, rebuilds did not help) and then the system calls it again with sound:
    /// the track is being recorded, so the failure is taken back while recording and is not in the manifest.
    @Test func systemAudioHeardAgainAfterGivingUpIsNotAFailedTrack() async throws {
        var policy = tapRecoveryTestPolicy; policy.maxConsecutiveFailures = 3
        let t = try TapSession(policy: policy); t.factory.hardware.othersPlaying = true
        let log = SystemAudioLog()
        let collecting = log.collect(await t.session.events())
        _ = try await t.session.start(.init(language: .ja))
        let tap = try #require(t.factory.tap)
        await settle(tap)
        var steps = 0
        while !log.all.contains("failed"), steps < 60 { t.host.advance(3); await settle(tap, or: { log.all.contains("failed") }); steps += 1 }
        #expect(log.all.contains("failed"))
        let feeder = feedTap(t.factory.hardware, host: t.host) { 0.25 }
        #expect(await soon { log.all.contains("recovered") })
        for _ in 0..<5 { t.host.advance(1); await settle(tap, fed: true) }
        feeder.cancel(); await feeder.value
        let m = try await t.session.stop()
        await collecting.value

        #expect(log.all.filter { $0 == "failed" || $0 == "recovered" } == ["failed", "recovered"])
        #expect(m.audioLoss?.contains { $0.sourceFailed } != true)
    }

    /// A microphone that could not be opened at the start and is attached later records from then on: the failure is
    /// taken back. No silence warning comes on top of the failure meanwhile.
    @Test func aMicrophoneAttachedAfterItsFailureIsNotAFailedTrack() async throws {
        let h = try await SessionHarness.make(mic: FakeAudioSource(track: .mic, startError: FakeError(message: "boom")))
        let events = await h.session.events()
        _ = try await h.session.start(.init(language: .ja))
        h.clock.advance(20)
        await h.session.tick()                               // 15 s of "silence" on a track already said to have failed
        let newMic = FakeAudioSource(track: .mic)
        h.factory.nextMicrophone = newMic
        try await h.session.attachMicrophone(deviceUID: nil)
        await newMic.emit(AudioFixtures.tone(start: 20, seconds: 5))
        h.clock.advance(5)
        let m = try await h.session.stop()

        let received = await eventsUntilStopped(events)
        let words = received.compactMap { event -> String? in
            switch event {
            case .sourceFailed(.mic, _): "failed"
            case .sourceRecovered(.mic): "recovered"
            case .silenceWarning(let w) where w.track == .mic: "silence"
            default: nil
            }
        }
        #expect(words == ["failed", "recovered"])
        #expect(m.audioLoss == nil)
    }

    /// A writer's failure is not taken back by a new microphone: that track drops every later chunk.
    @Test func aWriterFailureStaysWhateverTheSourceDoes() async throws {
        let h = try await SessionHarness.make()
        let events = await h.session.events()
        _ = try await h.session.start(.init(language: .ja))
        await h.session.reportWriterFailures([(.mic, FakeError(message: "boom"))])
        h.factory.nextMicrophone = FakeAudioSource(track: .mic)
        try await h.session.attachMicrophone(deviceUID: nil)
        h.clock.advance(5)
        let m = try await h.session.stop()

        let received = await eventsUntilStopped(events)
        #expect(!received.contains { if case .sourceRecovered = $0 { true } else { false } })
        #expect(m.audioLoss?.first == TrackLoss(track: .mic, seconds: 0, sourceFailed: true))
    }
}
