import Testing
import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

/// F4: every way a recording starts or stops reaches the log with its origin and `StopReason` (spec §5.1).
/// The values are checked as the coordinator hands them to the log (`onTransition`), not through `Logger`.
///
/// Every path that ends a recording (the `stop` paths), and the test that covers it:
///
/// | Path | Origin | StopReason given to the recorder | Test |
/// |---|---|---|---|
/// | Shortcut ⌃⌥R (`AppModel.toggleRecording`) | hotkey | manual | `userStopFromEachPlace`, `AppModelOriginTests` |
/// | Menu bar 「停止」 | menu | manual | `userStopFromEachPlace`, `AppModelOriginTests` |
/// | Main window 「停止」 | window | manual | `userStopFromEachPlace`, `AppModelOriginTests` |
/// | Notification button (none stops today; listed for completeness) | notificationAction | manual | `userStopFromEachPlace` |
/// | CLI `autonote stop` (`CommandRouter`) | cli | manual | `userStopFromEachPlace`, `CommandRouterOriginTests` |
/// | Quit while recording (`AppDelegate.stopAndAwaitJob`) | terminating | appTerminating | `quitStopsWithAppTerminating` |
/// | Grace period ran out after the origin device left | graceExpired | deviceGone | `graceExpiryStopsWithDeviceGone` |
/// | Disk below 500 MB (`RecordingSession` stops itself) | diskFull | — (already stopped) | `diskFullSelfStop`, `adapterReportsOnlyUnrequestedStops` |
/// | Any other stop the recorder made itself | sessionEnded | — (already stopped) | `otherSelfStop` |
/// | Start failed (recording → idle inside the start) | startFailed | — | `failedStartIsLabelled` |
@Suite(.timeLimit(.minutes(1))) struct RecordingControlOriginTests {
    /// Collects what `onTransition` receives.
    final class Transitions: Sendable {
        private let box = Mutex<[RecorderTransitionRecord]>([])
        var all: [RecorderTransitionRecord] { box.withLock { $0 } }
        /// Only the records that changed the state.
        var changes: [RecorderTransitionRecord] { all.filter { $0.from != $0.to } }
        var last: RecorderTransitionRecord? { changes.last }
        func append(_ r: RecorderTransitionRecord) { box.withLock { $0.append(r) } }
    }

    private func harness(countdown: Int = 5) async throws -> (CoordinatorHarness, Transitions) {
        let log = Transitions()
        let h = try await CoordinatorHarness(
            config: AutoRecordConfig(countdownSeconds: countdown, graceSeconds: 30, language: .ja, startOnModelMatch: false),
            onTransition: { log.append($0) })
        return (h, log)
    }

    // MARK: - Stops

    @Test(arguments: [RecordingControlOrigin.hotkey, .menu, .window, .notificationAction, .cli])
    func userStopFromEachPlace(_ origin: RecordingControlOrigin) async throws {
        let (h, log) = try await harness()
        let port = CoordinatorRecorderPort(coordinator: h.coordinator)
        try await port.start(language: nil, origin: origin)
        try await port.stop(origin: origin)
        #expect(log.changes.map(\.origin) == [origin, origin])
        let stop = try #require(log.last)
        #expect(stop.from == .recording && stop.to == .idle && stop.event == "manualStop")
        #expect(stop.stopReason == .manual)
        #expect(stop.meetingID == MeetingID(rawValue: "fake-meeting-1"))
        #expect(await h.recorder.stopReasons == [.manual])
    }

    @Test func quitStopsWithAppTerminating() async throws {
        let (h, log) = try await harness()
        await h.startAutoRecording()
        await h.coordinator.stop(origin: .terminating)
        let stop = try #require(log.last)
        #expect(stop.origin == .terminating && stop.stopReason == .appTerminating && stop.to == .idle)
        #expect(await h.recorder.stopReasons == [.appTerminating])
    }

    @Test func graceExpiryStopsWithDeviceGone() async throws {
        let (h, log) = try await harness()
        await h.startAutoRecording()
        await h.coordinator.handle(.removed(h.A))
        await h.timer.advance(by: 30)
        let changes = log.changes
        #expect(changes.map(\.origin) == [.deviceConnected, .countdownFired, .deviceDisconnected, .graceExpired])
        #expect(changes[2].from == .recording && changes[2].to == .grace && changes[2].stopReason == nil)
        #expect(changes[3].from == .grace && changes[3].to == .idle && changes[3].stopReason == .deviceGone)
        #expect(await h.recorder.stopReasons == [.deviceGone])
    }

    @Test func diskFullSelfStop() async throws {
        let (h, log) = try await harness()
        try await h.startRunning()
        await h.startAutoRecording()
        await h.recorder.emitSelfStop(reason: .diskFull)
        try await h.waitUntil { await h.coordinator.current().state == .idle }
        let stop = try #require(log.last)
        #expect(stop.event == "sessionEnded" && stop.origin == .diskFull && stop.from == .recording)
        #expect(stop.stopReason == nil)   // the recorder stopped itself; nothing more is asked of it
        #expect(await h.recorder.stopCount == 0)
        await h.stopRunning()
    }

    @Test func otherSelfStop() async throws {
        let (h, log) = try await harness()
        try await h.startRunning()
        await h.startAutoRecording()
        await h.recorder.emitSelfStop(reason: .manual)
        try await h.waitUntil { await h.coordinator.current().state == .idle }
        #expect(log.last?.origin == .sessionEnded && log.last?.event == "sessionEnded")
        await h.stopRunning()
    }

    @Test func failedStartIsLabelled() async throws {
        let (h, log) = try await harness()
        await h.recorder.failStart()
        await #expect(throws: (any Error).self) { try await h.coordinator.manualStart(language: nil, origin: .menu) }
        #expect(log.changes.map(\.origin) == [.menu, .startFailed])
        #expect(log.changes.map(\.to) == [.recording, .idle])
    }

    // MARK: - Starts and the rest

    @Test func countdownAndDeviceStarts() async throws {
        let (h, log) = try await harness()
        await h.coordinator.handle(.added(h.A))
        #expect(log.last?.origin == .deviceConnected && log.last?.to == .countdown)
        await h.timer.advance(by: 5)
        #expect(log.last?.origin == .countdownFired && log.last?.to == .recording && log.last?.event == "timerFired")

        let (h0, log0) = try await harness(countdown: 0)
        await h0.coordinator.handle(.added(h0.A))
        #expect(log0.last?.origin == .deviceConnected && log0.last?.to == .recording)
    }

    @Test func countdownCancelledByUnplugOrButton() async throws {
        let (h, log) = try await harness()
        await h.coordinator.handle(.added(h.A))
        await h.coordinator.handle(.removed(h.A))
        #expect(log.last?.origin == .deviceDisconnected && log.last?.to == .idle)
        await h.coordinator.handle(.added(h.A))
        await h.coordinator.handle(.cancelCountdown, origin: .notificationAction)
        #expect(log.last?.origin == .notificationAction && log.last?.event == "cancelCountdown")
    }

    @Test func startNowFromNotice() async throws {
        let (h, log) = try await harness()
        try await h.startRunning(initial: [.fixtureBluetoothInput])
        await h.coordinator.handle(.startNow(h.A.deviceRef), origin: .notificationAction)
        #expect(log.last?.origin == .notificationAction && log.last?.event == "startForConnectedDevice")
        #expect(log.last?.to == .recording)
        await h.stopRunning()
    }

    @Test func pauseAndResumeCarryTheirOrigin() async throws {
        let (h, log) = try await harness()
        let port = CoordinatorRecorderPort(coordinator: h.coordinator)
        try await port.start(language: nil, origin: .window)
        try await port.pause(origin: .hotkey)
        try await port.resume(origin: .cli)
        #expect(log.changes.map(\.origin) == [.window, .hotkey, .cli])
        #expect(log.changes.map(\.to) == [.recording, .paused, .recording])
    }

    /// An event that changes nothing still reaches the sink, so an ignored stop is visible in the log too.
    @Test func ignoredEventIsStillRecorded() async throws {
        let (h, log) = try await harness()
        await h.coordinator.stop(origin: .hotkey)
        let r = try #require(log.all.last)
        #expect(r.from == .idle && r.to == .idle && r.origin == .hotkey && r.stopReason == nil)
    }

    @Test func logLineSaysWhatAndWhy() {
        let r = RecorderTransitionRecord(from: .recording, to: .idle, event: "manualStop", origin: .hotkey,
                                         stopReason: .manual, meetingID: MeetingID(rawValue: "2026-10-30-1158"))
        #expect(r.logLine == "recording -> idle on manualStop (origin: hotkey, stop: manual, meeting: 2026-10-30-1158)")
        let ignored = RecorderTransitionRecord(from: .idle, to: .idle, event: "manualStop", origin: .cli,
                                               stopReason: nil, meetingID: nil)
        #expect(ignored.logLine == "idle -> idle on manualStop (origin: cli) ignored")
    }

    @Test func stopReasonPerOrigin() {
        #expect(RecordingControlOrigin.terminating.stopReason == .appTerminating)
        #expect(RecordingControlOrigin.graceExpired.stopReason == .deviceGone)
        #expect(RecordingControlOrigin.diskFull.stopReason == .diskFull)
        for o in [RecordingControlOrigin.hotkey, .menu, .window, .notificationAction, .cli] { #expect(o.stopReason == .manual) }
    }
}

// MARK: - The entry points above the coordinator

@MainActor @Suite struct AppModelOriginTests {
    private func recording() -> RecorderSnapshot {
        RecorderSnapshot(state: .recording, meetingID: MeetingID(rawValue: "m1"), startedAt: Samples.start, language: .ja)
    }

    @Test func toggleFromHotkeyAndStopFromMenuAndWindow() async {
        let fakes = FakePorts(recorder: FakeRecorderPort(recording()))
        let model = AppModel(ports: fakes.ports, now: { Samples.start }, timeZone: Samples.tokyo)
        let task = Task { await model.run() }
        defer { task.cancel() }
        await model.settle()
        await model.perform(.toggleRecording, from: .hotkey)   // recording → stop
        await model.settle()
        await model.perform(.toggleRecording, from: .hotkey)   // idle → start
        await model.perform(.stop, from: .menu)
        await model.perform(.start, from: .window)
        await model.perform(.stop, from: .window)
        #expect(await fakes.recorder.calls == ["stop", "start(nil)", "stop", "start(nil)", "stop"])
        #expect(await fakes.recorder.origins == [.hotkey, .hotkey, .menu, .window, .window])
    }

    @Test func noticeActionsCarryTheirOrigin() async {
        let fakes = FakePorts()
        let model = AppModel(ports: fakes.ports)
        let ref = DeviceRef(name: "Fictional Headset", uid: "uid-1", transport: "bluetooth")
        await model.perform(.notice(.startNow(ref)), from: .notificationAction)
        await model.perform(.notice(.cancelCountdown), from: .window)
        await model.perform(.cancelCountdown, from: .menu)
        #expect(await fakes.recorder.origins == [.notificationAction, .window, .menu])
    }

    @Test func quitStopsAsTerminating() async {
        let fakes = FakePorts(recorder: FakeRecorderPort(recording()))
        let model = AppModel(ports: fakes.ports)
        await model.perform(.stop, from: .terminating)
        #expect(await fakes.recorder.origins == [.terminating])
    }
}

@Suite struct CommandRouterOriginTests {
    @Test func everyRecorderCommandIsFromTheCLI() async {
        let fakes = FakePorts()
        let router = CommandRouter(ports: fakes.ports)
        for cmd in [IPCCommand.start, .pause, .resume, .stop] {
            let r = await router.handle(IPCRequest(cmd: cmd, args: IPCArgs(), id: 1))
            #expect(r.ok)
        }
        #expect(await fakes.recorder.calls == ["start(nil)", "pause", "resume", "stop"])
        #expect(await fakes.recorder.origins == [.cli, .cli, .cli, .cli])
    }
}
