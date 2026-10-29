import Testing
import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

private let deviceA = DeviceIdentity(raw: .fixtureBluetoothInput)!.deviceRef
private let uidA = deviceA.uid

/// Runs `reattach` and advances the manual clock by one retry interval whenever the reattacher is sleeping.
private func runReattach(_ control: FakeRecordingControl, _ timer: ManualTimerScheduler) async throws -> ReattachOutcome {
    let done = Mutex(false)
    let task = Task {
        let outcome = await MicrophoneReattacher(control: control, timer: timer).reattach(uid: uidA)
        done.withLock { $0 = true }
        return outcome
    }
    while !done.withLock({ $0 }) {
        try await waitUntil { timer.pendingCount == 1 || done.withLock { $0 } }
        if timer.pendingCount == 1 { await timer.advance(by: 0.5) }
    }
    return await task.value
}

/// True when `stream` yields an element within `limit` (the reading task is cancelled otherwise).
private func receives(_ stream: AsyncStream<Void>, within limit: Duration) async -> Bool {
    let reader = Task { var iterator = stream.makeAsyncIterator(); return await iterator.next() != nil }
    let deadline = Task { try? await Task.sleep(for: limit); reader.cancel() }
    let received = await reader.value
    deadline.cancel()
    return received
}

private struct OtherError: Error {}

/// A microphone whose `stop` blocks until `release()`, so a test can hold a session stop in flight.
private final class GatedAudioSource: AudioSource, @unchecked Sendable {
    let track = Track.mic
    // All state guarded by `lock`.
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private var entered = false

    var stopEntered: Bool { lock.withLock { entered } }

    func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws {}

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                entered = true
                if released { return true }
                waiting = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { released = true; let c = waiting; waiting = nil; return c }
        continuation?.resume()
    }
}

private struct GatedSourceFactory: AudioSourceFactory {
    let mic: GatedAudioSource
    let system = FakeAudioSource(track: .system)
    func makeSystemSource(clock: MeetingClock) -> any AudioSource { system }
    func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource { mic }
    func inputDevice(uid: String?) -> DeviceRef? { FakeAudioSourceFactory.defaultInput }
}

enum AttachFailure: String, CaseIterable, Sendable {
    case deviceNotFound, coreAudio, timedOut, microphonePermission, notRecording, other

    var error: any Error {
        switch self {
        case .deviceNotFound: AudioSourceError.deviceNotFound(uid: uidA)
        case .coreAudio: AudioSourceError.coreAudio(call: "AudioDeviceStart", status: -1)
        case .timedOut: AudioSourceError.timedOut(call: "AudioDeviceStart")
        case .microphonePermission: AudioSourceError.microphonePermission(.denied)
        case .notRecording: RecordingError.notRecording
        case .other: OtherError()
        }
    }
}

@Suite struct MicrophoneReattacherTests {
    @Test func succeedsAfterRetries() async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 3)
        #expect(try await runReattach(control, timer) == .device(attempts: 4))
        #expect(await control.attachCalls == [uidA, uidA, uidA, uidA])
        #expect(timer.now == 1.5)
    }

    @Test func fallsBackToDefaultAfter20() async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 20)
        #expect(try await runReattach(control, timer) == .fallbackToDefault)
        let calls = await control.attachCalls
        #expect(calls.count == 21)
        #expect(calls.last == .some(nil))
        #expect(calls.filter { $0 == uidA }.count == 20)
    }

    @Test func reportsFailedWhenDefaultFails() async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 20)
        await control.failDefaultAttach()
        #expect(try await runReattach(control, timer) == .failed)
        #expect(await control.attachCalls.count == 21)
    }

    @Test func doesNotWaitBeforeFirstAttempt() async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 1)
        let task = Task { await MicrophoneReattacher(control: control, timer: timer).reattach(uid: uidA) }
        try await waitUntil { await control.attachCalls.count == 1 }
        #expect(timer.now == 0)
        try await waitUntil { timer.pendingCount == 1 }
        await timer.advance(by: 0.5)
        #expect(await task.value == .device(attempts: 2))
    }

    @Test(arguments: [AttachFailure.deviceNotFound, .coreAudio, .timedOut])
    func retryableErrorsAreRetried(_ failure: AttachFailure) async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 2, error: failure.error)
        #expect(try await runReattach(control, timer) == .device(attempts: 3))
    }

    @Test(arguments: [AttachFailure.microphonePermission, .notRecording, .other])
    func nonRetryableErrorsFailImmediately(_ failure: AttachFailure) async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 1, error: failure.error)
        #expect(try await runReattach(control, timer) == .failed)
        #expect(await control.attachCalls == [uidA])
        #expect(timer.scheduledCount == 0)
    }

    @Test(arguments: [AttachFailure.microphonePermission, .notRecording, .other])
    func nonRetryableErrorDuringFallbackFails(_ failure: AttachFailure) async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 20)
        await control.failDefaultAttach(error: failure.error)
        #expect(try await runReattach(control, timer) == .failed)
        #expect(await control.attachCalls.count == 21)
    }

    @Test func cancelledReattachStopsRetrying() async throws {
        let control = FakeRecordingControl(), timer = ManualTimerScheduler()
        await control.failAttach(uid: uidA, times: 20)
        let task = Task { await MicrophoneReattacher(control: control, timer: timer).reattach(uid: uidA) }
        try await waitUntil { timer.pendingCount == 1 }
        await timer.advance(by: 0.5)
        try await waitUntil { timer.pendingCount == 1 }
        task.cancel()
        await timer.advance(by: 10)
        #expect(await task.value == .failed)
        #expect(await control.attachCalls.count <= 3)
    }

    // MARK: - RecordingSessionControl (`RecordingSession` adapter)

    @Test func adapterReportsOnlyUnrequestedStops() async throws {
        let h = try await SessionHarness.make()
        let control = RecordingSessionControl(session: h.session)
        let selfStops = await control.selfStops()
        let otherSelfStops = await control.selfStops()
        let events = await h.session.events()

        _ = try await control.start(device: nil, language: .ja, manual: true)
        await control.stop(reason: .manual)
        _ = try await withTimeout(.seconds(5)) { await eventsUntilStopped(events) }

        _ = try await control.start(device: nil, language: .ja, manual: true)
        h.disk.bytes = 100_000_000
        await h.session.tick()
        let received = try await withTimeout(.seconds(5)) { await eventsUntilStopped(events) }
        guard case .stopped(_, .diskFull) = received.last else {
            Issue.record("expected .stopped(_, .diskFull), got \(String(describing: received.last))"); return
        }
        // The adapter forwards in event order, so a leaked manual stop would already be buffered ahead of this one.
        #expect(await receives(selfStops, within: .seconds(5)))
        #expect(await !receives(selfStops, within: .milliseconds(200)))
        #expect(await receives(otherSelfStops, within: .seconds(5)))     // every stream gets the self-stop
        #expect(await !receives(otherSelfStops, within: .milliseconds(200)))
    }

    @Test func adapterStopWhileIdleDoesNotSwallowLaterSelfStop() async throws {
        let h = try await SessionHarness.make()
        let control = RecordingSessionControl(session: h.session)
        let selfStops = await control.selfStops()
        let events = await h.session.events()
        await control.stop(reason: .diskFull)                   // idle: throws notRecording, so the marker is cleared
        #expect(await control.expectingOwnStop == nil)

        _ = try await control.start(device: nil, language: .ja, manual: true)
        h.disk.bytes = 100_000_000
        await h.session.tick()
        _ = try await withTimeout(.seconds(5)) { await eventsUntilStopped(events) }
        #expect(await receives(selfStops, within: .seconds(5)))
    }

    /// Real-session path: the disk-full stop is held inside the microphone's `stop` while our `.manual` stop waits
    /// at the session's gate, so the `.stopped(_, .diskFull)` arrives while our own stop is in flight.
    @Test func adapterForwardsDifferentReasonSelfStopDuringOwnStop() async throws {
        let mic = GatedAudioSource()
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let disk = FakeDiskSpace()
        let session = RecordingSession(paths: paths, manifests: ManifestStore(paths: paths),
                                       sources: GatedSourceFactory(mic: mic), host: FakeHostClock(), disk: disk,
                                       now: { Samples.start }, tickInterval: .seconds(3600), timeZone: Samples.tokyo)
        let control = RecordingSessionControl(session: session)
        let selfStops = await control.selfStops()
        _ = try await control.start(device: nil, language: .ja, manual: true)

        disk.bytes = 100_000_000
        await session.tick()                                    // spawns the disk-full stop
        try await waitUntil { mic.stopEntered }                 // ...which now holds the session's gate
        let ownStop = Task { await control.stop(reason: .manual) }
        try await waitUntil { await control.expectingOwnStop == .manual }
        mic.release()

        #expect(await receives(selfStops, within: .seconds(5)))
        await ownStop.value                                     // throws notRecording inside: marker cleared
        #expect(await control.expectingOwnStop == nil)
        #expect(await session.state == .idle)
    }

    @Test func fakeSelfStopsReachEveryStream() async throws {
        let control = FakeRecordingControl()
        let first = await control.selfStops(), second = await control.selfStops()
        await control.emitSelfStop()
        #expect(await receives(first, within: .seconds(5)))
        #expect(await receives(second, within: .seconds(5)))
    }

    @Test func adapterPassesMicrophoneUID() async throws {
        let h = try await SessionHarness.make()
        let control = RecordingSessionControl(session: h.session)
        _ = try await control.start(device: deviceA, language: .ja, manual: false)
        #expect(h.factory.microphoneUIDs == [uidA])
        let withDevice = try await h.session.stop(reason: .manual)
        #expect(withDevice.device == deviceA)

        let h2 = try await SessionHarness.make()
        let control2 = RecordingSessionControl(session: h2.session)
        _ = try await control2.start(device: nil, language: .ja, manual: true)
        #expect(h2.factory.microphoneUIDs == [nil])
        let withoutDevice = try await h2.session.stop(reason: .manual)
        #expect(withoutDevice.device == FakeAudioSourceFactory.defaultInput)
    }

    @Test func adapterForwardsBookmarkAndLanguage() async throws {
        let h = try await SessionHarness.make()
        let control = RecordingSessionControl(session: h.session)
        let id = try await control.start(device: nil, language: .ja, manual: true)
        let bookmark = try await control.bookmark(note: "x")
        #expect(bookmark.note == "x")
        await control.setLanguage(.en)
        let manifest = try await h.manifests.load(id)
        #expect(manifest.language == .en)
        #expect(manifest.bookmarks == [bookmark])
        _ = try await h.session.stop(reason: .manual)
    }
}
