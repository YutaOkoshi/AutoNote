import Foundation
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

@MainActor @Suite struct AppModelTests {
    private let now = Samples.start
    private let m1 = MeetingID(rawValue: "20261024-1400-a1b2")
    private let device = DeviceRef(name: "Kestrel Headset 7", uid: "FAKE-KESTREL-0001:input", transport: "bluetooth")

    /// Starts `run()` and waits until every stream is subscribed and drained. Cancel the returned task at the end.
    private func start(_ fakes: FakePorts) async -> (AppModel, Task<Void, Never>) {
        let now = now
        let model = AppModel(ports: fakes.ports, now: { now }, timeZone: Samples.tokyo)
        let task = Task { await model.run() }
        await model.settle()
        return (model, task)
    }

    private func recording(_ id: MeetingID? = MeetingID(rawValue: "20261024-1400-a1b2")) -> RecorderSnapshot {
        RecorderSnapshot(state: .recording, meetingID: id, startedAt: now - 754, deviceName: "Jabra", language: .ja)
    }

    private func run(_ name: String, _ id: MeetingID, ok: Bool) -> AutomationRunRecord {
        AutomationRunRecord(name: name, event: .minutesGenerated, meetingID: id.rawValue, startedAt: now, durationSeconds: 1,
                            exitCode: ok ? 0 : 1, timedOut: false, skippedReason: nil, logDirectory: "/tmp/log")
    }

    @Test func recorderSnapshotDrivesMenuBar() async {
        // recording の snapshot → menuBar(now:).symbol == "record.circle"
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.menuBar(now: now).symbol == "waveform")
        await fakes.recorder.setElapsed(TimelineTime(seconds: 754))
        await fakes.recorder.send(recording())
        await model.settle()
        #expect(model.recorder.state == .recording)
        #expect(model.menuBar(now: now).symbol == "record.circle" && model.menuBar(now: now).title == "12:34")
    }

    @Test func liveUpdatesAndResetOnNewMeeting() async {
        // FakeLiveTranscriptPort が [Utterance] を 2 回流す → live.lines は後の方。.started で空（X25）
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.live.send([u(1, .me, "一回目")])
        await fakes.live.send([u(1, .me, "一回目"), u(2, .other, "二回目")])
        await model.settle()
        #expect(model.live.lines == [.utterance(u(1, .me, "一回目")), .utterance(u(2, .other, "二回目"))])
        await fakes.events.send(.started(MeetingID(rawValue: "20261024-1500-c3d4")))
        await model.settle()
        #expect(model.live.lines.isEmpty)
    }

    @Test func queueChangeRefreshesMeetings() async {
        // QueueStatus の (meetingID, state, stage, awaitingConfirmation) が変わるたび rows() が増える。進み具合だけなら増えない（X20）
        let fakes = FakePorts()
        await fakes.meetings.send([MeetingRow(id: m1.rawValue, startedAt: now, state: .processing)])
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        func rowsCalls() async -> Int { await fakes.meetings.calls.filter { $0 == "rows" }.count }
        let initial = await rowsCalls()
        #expect(initial == 1 && model.meetings.count == 1)
        await fakes.queue.send(QueueStatus(items: [QueueItemDTO(meetingID: m1.rawValue, stage: "transcribe", state: "running", progress: 0.1)]))
        await model.settle()
        #expect(await rowsCalls() == 2)
        await fakes.queue.send(QueueStatus(items: [QueueItemDTO(meetingID: m1.rawValue, stage: "transcribe", state: "running", progress: 0.5)]))
        await model.settle()
        #expect(await rowsCalls() == 2 && model.queue.items.first?.progress == 0.5)
        await fakes.queue.send(QueueStatus(items: [QueueItemDTO(meetingID: m1.rawValue, stage: "summarize", state: "running")]))
        await model.settle()
        #expect(await rowsCalls() == 3)
    }

    @Test func actionsForwarded() async {
        // .bookmark("x") → calls == ["bookmark(x)"]。.toggleRecording は idle → start、recording → stop。.togglePause は recording → pause、paused → resume
        let fakes = FakePorts(recorder: FakeRecorderPort(recording()))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await model.perform(.bookmark("x"))
        #expect(await fakes.recorder.calls == ["bookmark(x)"])
        await model.perform(.togglePause)
        await model.settle()
        await model.perform(.togglePause)
        await model.settle()
        await model.perform(.toggleRecording)
        await model.settle()
        #expect(model.recorder.state == .idle)
        await model.perform(.toggleRecording)
        await model.settle()
        #expect(await fakes.recorder.calls == ["bookmark(x)", "pause", "resume", "stop", "start(nil)"] && model.lastError == nil)
        // togglePause outside recording/paused does nothing (X34).
        await fakes.recorder.send(RecorderSnapshot(state: .grace, meetingID: m1, deadline: now + 10, language: .ja))
        await model.settle()
        await model.perform(.togglePause)
        await model.perform(.toggleRecording)   // grace → stop
        #expect(await fakes.recorder.calls.suffix(1) == ["stop"])
        await fakes.recorder.send(RecorderSnapshot(state: .countdown, deviceName: "Jabra", deadline: now + 3, language: .ja))
        await model.settle()
        await model.perform(.toggleRecording)   // countdown → start
        await model.perform(.cancelCountdown)
        await model.perform(.setLanguage(.en))
        await model.perform(.regenerate(m1))
        await model.perform(.delete(m1))
        await model.perform(.rerunAutomation(name: "slack", meetingID: m1))
        #expect(await fakes.recorder.calls.suffix(4) == ["stop", "start(nil)", "cancelCountdown", "setLanguage(en)"])
        #expect(await fakes.queue.calls == ["regenerate(\(m1.rawValue))", "delete(\(m1.rawValue))"])
        #expect(await fakes.automations.calls.contains("run(slack,\(m1.rawValue))"))
        await model.perform(.open(m1))
        #expect(model.selectedMeetingID == m1)
    }

    @Test func importAndOpenLatest() async {
        let fakes = FakePorts()
        await fakes.meetings.send([MeetingRow(id: m1.rawValue, startedAt: now, state: .minutesGenerated, filePath: "/v/a.md")])
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.menuBar(now: now).items.contains(.openLatestMinutes(enabled: true)))
        await model.perform(.openLatestMinutes)
        #expect(await fakes.opener.opened == [URL(filePath: "/v/a.md")])
        await model.perform(.importAudio(URL(filePath: "/tmp/in.m4a"), startedAt: nil))
        #expect(await fakes.meetings.calls.contains("importAudio(/tmp/in.m4a)"))
        #expect(model.selectedMeetingID == MeetingID(rawValue: "20261024-1400-0000"))
        await fakes.meetings.send([])
        await model.refresh()
        await model.perform(.openLatestMinutes)
        #expect(model.lastError == "議事録がまだありません")
    }

    @Test func errorsSurfaceWithRouterWording() async {
        // nextError .notRecording → lastError == "録音中ではありません"
        let fakes = FakePorts(recorder: FakeRecorderPort(recording()))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.recorder.setNextError(.notRecording)
        await model.perform(.stop)
        #expect(model.lastError == "録音中ではありません")
        await fakes.queue.setNextError(.notFound("会議が見つかりません: x"))
        await model.perform(.regenerate(m1))
        #expect(model.lastError == "会議が見つかりません: x")
    }

    @Test func automationFailureCollectedAndCleared() async {
        // 失敗記録 → 1 件。同名・同会議の成功で消える。起動時は recentRuns(limit: 20) の失敗から始める（X6）
        let fakes = FakePorts()
        let m2 = MeetingID(rawValue: "20261024-1500-c3d4")
        await fakes.automations.send(run("notion", m2, ok: false))
        var skipped = run("skip", m2, ok: false)
        skipped.skippedReason = "already_ran"
        await fakes.automations.send(skipped)
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(await fakes.automations.calls.contains("recentRuns(20)"))
        #expect(model.automationFailures.map(\.name) == ["notion"])
        await fakes.automations.send(run("slack", m1, ok: false))
        await fakes.automations.send(run("slack", m1, ok: false))
        await model.settle()
        #expect(model.automationFailures.count == 2 && model.automationFailures.filter { $0.name == "slack" }.count == 1)
        await fakes.automations.send(run("slack", m2, ok: true))     // another meeting: not cleared
        await fakes.automations.send(run("slack", m1, ok: true))
        await model.settle()
        #expect(model.automationFailures.map(\.name) == ["notion"])
    }

    @Test func diskWarnings() async {
        // .diskSpaceLow → "ディスクの空きが 1GB を切りました"、.stopped(m, .diskFull) → "ディスクの空きが 500MB を切ったため録音を停止しました"
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.diskWarning == nil)
        await fakes.events.send(.diskSpaceLow(availableBytes: 900_000_000))
        await model.settle()
        #expect(model.diskWarning == "ディスクの空きが 1GB を切りました")
        await fakes.events.send(.stopped(Samples.manifest, .diskFull))
        await model.settle()
        #expect(model.diskWarning == "ディスクの空きが 500MB を切ったため録音を停止しました")
        await fakes.events.send(.started(m1))
        await model.settle()
        #expect(model.diskWarning == nil)
    }

    @Test func noticeActionsRouted() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await model.perform(.notice(.cancelCountdown))
        await model.perform(.notice(.startNow(device)))
        await model.perform(.notice(.registerDevice(device, answer: .yes)))
        #expect(await fakes.recorder.calls == ["handleNotice(cancelCountdown)", "handleNotice(\(UserNoticeAction.startNow(device)))",
                                               "handleNotice(\(UserNoticeAction.registerDevice(device, answer: .yes)))"])
        let id = m1.rawValue
        await model.perform(.notice(.retry(m1)))
        await model.perform(.notice(.resolveOverwrite(m1, overwrite: true)))
        await model.perform(.notice(.transcribeTooShort(m1)))
        await model.perform(.notice(.discardTooShort(m1)))
        #expect(await fakes.queue.calls == ["retry(\(id))", "resolveOverwrite(\(id),true)", "acceptShortRecording(\(id))", "delete(\(id))"])
        await model.perform(.notice(.recoverInterrupted(m1)))
        await model.perform(.notice(.discardInterrupted(m1)))
        #expect(await fakes.meetings.calls.suffix(2) == ["recover(\(id))", "discard(\(id))"])
        await model.perform(.notice(.openPrivacySettings))
        await model.perform(.notice(.openMeeting(m1)))
        #expect(model.selectedMeetingID == m1 && model.lastError == nil)
    }

    @Test func promptsKeptUntilAnswered() async {
        // noticePosted(.recordingTooShort(id)) → prompts 1 件。.notice(.discardTooShort(id)) か noticeWithdrawn(id:) で消える。.minutesGenerated は入れない
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        model.noticePosted(.recordingTooShort(m1))
        model.noticePosted(.recordingTooShort(m1))
        #expect(model.prompts == [.recordingTooShort(m1)])
        await model.perform(.notice(.discardTooShort(m1)))
        #expect(model.prompts.isEmpty)
        model.noticePosted(.interruptedRecordingFound(m1))
        model.noticePosted(.overwriteConfirmation(m1))
        model.noticePosted(.minutesGenerated(m1, title: "定例"))
        model.noticePosted(.diskLow(availableBytes: 1))
        #expect(model.prompts == [.interruptedRecordingFound(m1), .overwriteConfirmation(m1)])
        model.noticeWithdrawn(id: UserNotice.interruptedRecordingFound(m1).id)
        #expect(model.prompts == [.overwriteConfirmation(m1)])
        await model.perform(.notice(.resolveOverwrite(m1, overwrite: false)))
        #expect(model.prompts.isEmpty)
    }

    @Test func quitDecisionFollowsRecorder() async {
        let fakes = FakePorts(recorder: FakeRecorderPort(recording()))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.quitDecision(reason: .user) == .confirm && model.quitDecision(reason: .powerOff) == .stopThenTerminate)
    }

    @Test func runEndsWhenCancelled() async {
        let fakes = FakePorts()
        let (_, task) = await start(fakes)
        task.cancel()
        await task.value
    }
}
