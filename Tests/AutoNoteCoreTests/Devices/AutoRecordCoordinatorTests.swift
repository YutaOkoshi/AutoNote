import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite(.timeLimit(.minutes(1))) struct AutoRecordCoordinatorTests {
    @Test func registeredConnectStartsAfterCountdown() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator, A = h.A
        await c.handle(.added(A))
        #expect(await h.notifier.posted == [.deviceConnectedCountdown(A.deviceRef, seconds: 5)])
        await h.timer.advance(by: 4.9); #expect(await h.recorder.starts.isEmpty)
        await h.timer.advance(by: 0.1)
        let starts = await h.recorder.starts
        #expect(starts.count == 1 && starts[0].0 == A.deviceRef && starts[0].2 == false)
        #expect(await h.notifier.withdrawn.contains("device.countdown"))
        #expect(await c.current().state == .recording)
    }

    @Test func cancelCountdownPreventsStart() async throws {
        let h = try await CoordinatorHarness()
        await h.coordinator.handle(.added(h.A))
        await h.coordinator.cancelCountdown()
        await h.timer.advance(by: 5)
        #expect(await h.recorder.starts.isEmpty)
        #expect(await h.coordinator.current().state == .idle)
    }

    @Test func originDisconnectStopsAfterGrace() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator, A = h.A
        await h.startAutoRecording()
        await c.handle(.removed(A))
        #expect(await h.recorder.detachCount == 1)
        #expect(await c.current().banner == "機材が外れました。30 秒後に停止")
        #expect(await h.notifier.posted.contains(.deviceGoneGrace(A.deviceRef, seconds: 30)))
        await h.timer.advance(by: 29.9)
        #expect(await h.recorder.stopCount == 0)
        await h.timer.advance(by: 0.1)
        #expect(await h.recorder.stopCount == 1)
        #expect(await h.recorder.stopReasons == [.deviceGone])
        #expect(await c.current().banner == nil)
        #expect(await h.notifier.withdrawn.contains("device.grace"))
    }

    @Test func graceReturnReattachesSameDevice() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator, A = h.A
        await h.startAutoRecording()
        await c.handle(.removed(A))
        await c.handle(.added(A))
        try await h.waitUntil { await h.recorder.attachCalls == [A.deviceUID] }
        #expect(await c.current().state == .recording)
        #expect(await h.recorder.stopCount == 0)
    }

    @Test func reattachFallbackShowsBanner() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator, A = h.A
        await h.recorder.failAttach(uid: A.deviceUID, times: 20)
        await h.startAutoRecording()
        await c.handle(.removed(A))
        await c.handle(.added(A))
        // advance(10) in 0.5 s steps (Y4): each step waits until the reattacher is sleeping on the manual clock.
        for _ in 0..<20 {
            try await h.waitUntil {
                if h.timer.pendingCount == 1 { return true }
                return await c.current().banner == Banner.micFallback
            }
            if h.timer.pendingCount == 1 { await h.timer.advance(by: 0.5) }
        }
        try await h.waitUntil { (await c.current().banner) == Banner.micFallback }
        #expect(await h.recorder.attachCalls.last == .some(nil))
        #expect(await c.current().banner == Banner.micFallback)
        #expect(await c.current().state == .recording)
    }

    @Test func manualStartUsesDefaultInputAndIgnoresDisconnect() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        try await c.manualStart(language: .en)
        let starts = await h.recorder.starts
        #expect(starts.count == 1)
        #expect(starts[0].0 == nil && starts[0].1 == .en && starts[0].2 == true)
        #expect(await c.current().isManual)
        await c.handle(.removed(h.A))
        #expect(await c.current().state == .recording)
        #expect(await h.recorder.detachCount == 0)
    }

    @Test func manualStartFailureThrows() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        await h.recorder.failStart()
        await #expect(throws: RecordingError.self) { try await c.manualStart(language: nil) }
        #expect(await c.current().state == .idle)
        #expect(await c.current().banner == Banner.startFailed)
    }

    @Test func autoStartFailureShowsBanner() async throws {
        let h = try await CoordinatorHarness()
        await h.recorder.failStart()
        await h.startAutoRecording()
        #expect(await h.recorder.starts.count == 1)
        #expect(await h.coordinator.current().state == .idle)
        #expect(await h.coordinator.current().banner == Banner.startFailed)
    }

    @Test func autoStartUsesConfiguredLanguage() async throws {
        let h = try await CoordinatorHarness()
        h.setConfig(AutoRecordConfig(countdownSeconds: 5, graceSeconds: 30, language: .en, startOnModelMatch: false))
        await h.startAutoRecording()
        let starts = await h.recorder.starts
        #expect(starts.count == 1 && starts[0].1 == .en)
        #expect(await h.coordinator.current().language == .en)
    }

    @Test func pauseResumeStopRouteToRecorder() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        await h.startAutoRecording()
        await c.pause()
        #expect(await c.current().state == .paused)
        await c.resume()
        #expect(await c.current().state == .recording)
        await c.stop()
        #expect(await h.recorder.pauseCount == 1)
        #expect(await h.recorder.resumeCount == 1)
        #expect(await h.recorder.stopCount == 1)
        #expect(await h.recorder.stopReasons == [.manual])
        #expect(await c.current().state == .idle)
    }

    @Test func bookmarkOnlyWhileRecording() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        await #expect(throws: AutoRecordError.notRecording) { _ = try await c.bookmark(note: "x") }
        await h.startAutoRecording()
        _ = try await c.bookmark(note: "x")
        #expect(await h.recorder.bookmarks == ["x"])
        await c.handle(.removed(h.A))
        #expect(await c.current().state == .grace)
        _ = try await c.bookmark(note: "x")
        #expect(await h.recorder.bookmarks == ["x", "x"])
    }

    @Test func setLanguageWhileRecordingAndIdle() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        await h.startAutoRecording()
        await c.setLanguage(.en)
        #expect(await h.recorder.languages == [.en])
        #expect(await c.current().language == .en)
        await c.stop()
        #expect(await c.current().language == .ja)

        await c.setLanguage(.auto)
        #expect(await h.recorder.languages == [.en])
        #expect(await c.current().language == .auto)
        await h.startAutoRecording()
        let starts = await h.recorder.starts
        #expect(starts.count == 2 && starts[1].1 == .auto)
        await c.stop()
        #expect(await c.current().language == .ja)
    }

    @Test func selfStopReturnsToIdleWithoutStopCall() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        try await h.startRunning()
        await h.startAutoRecording()
        #expect(await c.current().state == .recording)
        await h.recorder.emitSelfStop()
        try await h.waitUntil { await c.current().state == .idle }
        #expect(await h.recorder.stopCount == 0)
        await h.stopRunning()
    }

    @Test func quickUnplugCallsStopOnce() async throws {
        let h = try await CoordinatorHarness()
        await h.startAutoRecording()
        await h.timer.advance(by: 10)
        await h.coordinator.handle(.removed(h.A))
        await h.timer.advance(by: 30)
        #expect(await h.recorder.stopCount == 1)
    }

    @Test func secondRegisteredDeviceIgnoredWhileRecording() async throws {
        let h = try await CoordinatorHarness()
        await h.startAutoRecording()
        await h.coordinator.handle(.added(h.B))
        let countdowns = await h.notifier.posted.filter {
            if case .deviceConnectedCountdown = $0 { true } else { false }
        }
        #expect(countdowns == [.deviceConnectedCountdown(h.A.deviceRef, seconds: 5)])
        #expect(await h.recorder.starts.count == 1)
        #expect(await h.coordinator.current().state == .recording)
    }

    // Expected sequence, derived from RecorderStateMachine and the coordinator's effect execution:
    // 1. subscribing yields the current value: idle (language .ja, no deadline).
    // 2. `.added(A)` with A registered -> (idle, deviceConnected(A, entryID)) -> countdown with effects
    //    [postCountdownNotice(A, 5), scheduleTimer(5, token 1)]; the snapshot carries deviceName A and deadline now + 5.
    // 3. advance(5) fires token 1 -> (countdown, timerFired(1)) -> recording with effects
    //    [dismissCountdownNotice, startRecording(.device(A), .auto)]. Before awaiting `recorder.start` the coordinator
    //    emits "recording, starting" (meetingID nil, deadline cleared) ...
    // 4. ... and once `start` returns, "recording" with meetingID fake-meeting-1 and startedAt = now.
    // Snapshots equal to the previous one are not re-emitted. The brief's "3 件" counts distinct states, so the test
    // asserts the de-duplicated state sequence [idle, countdown, recording] and the fields of the last snapshot (Y11).
    @Test func snapshotsStreamEachTransition() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator, A = h.A
        let stream = await c.snapshots()
        await c.handle(.added(A))
        await h.timer.advance(by: 5)
        var seen: [RecorderSnapshot] = []
        for await snapshot in stream {
            seen.append(snapshot)
            if snapshot.meetingID != nil { break }
        }
        let states = seen.map(\.state).reduce(into: [RecorderState]()) { if $0.last != $1 { $0.append($1) } }
        #expect(states == [.idle, .countdown, .recording])
        #expect(seen.map(\.state) == [.idle, .countdown, .recording, .recording])
        let countdown = try #require(seen.first { $0.state == .countdown })
        #expect(countdown.deadline == CoordinatorHarness.base.addingTimeInterval(5))
        #expect(countdown.deviceName == A.name)
        let last = try #require(seen.last)
        #expect(last.meetingID == MeetingID(rawValue: "fake-meeting-1"))
        #expect(last.startedAt == CoordinatorHarness.base.addingTimeInterval(5))
        #expect(last.deviceName == A.name)
        #expect(last.deadline == nil && last.isManual == false && last.language == .ja && last.banner == nil)
    }

    @Test func runRoutesMonitorEventsUntilCancelled() async throws {
        let h = try await CoordinatorHarness()
        let c = h.coordinator
        try await h.startRunning()
        h.connect(.fixtureBluetoothInput)
        try await h.waitUntil { await c.current().state == .countdown }
        h.disconnect(.fixtureBluetoothInput)
        try await h.waitUntil { await c.current().state == .idle }
        #expect(await h.notifier.withdrawn.contains("device.countdown"))
        await h.stopRunning()
    }

    @Test func configFromSettingsCopiesDeviceFields() {
        var settings = Settings()
        settings.countdownSeconds = 12; settings.disconnectGraceSeconds = 45
        settings.defaultLanguage = .en; settings.startOnModelMatch = true
        #expect(AutoRecordCoordinator.config(from: settings)
            == AutoRecordConfig(countdownSeconds: 12, graceSeconds: 45, language: .en, startOnModelMatch: true))
    }
}
