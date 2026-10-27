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

    /// Polls `condition` every few milliseconds until it holds or `timeout` passes (the caller's `#expect` then fails).
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
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

    @Test func overwritePromptDerivedFromQueueState() async {
        // 上書き確認待ちのジョブがある QueueStatus → post なしでも prompts に出る（I1）。確認待ちでなくなれば消える
        let awaiting = QueueItemDTO(meetingID: m1.rawValue, stage: "write_vault", state: "waiting", awaitingConfirmation: true)
        let fakes = FakePorts(queue: FakeQueuePort(QueueStatus(items: [awaiting])))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.prompts == [.overwriteConfirmation(m1)])
        model.noticePosted(.overwriteConfirmation(m1))
        #expect(model.prompts == [.overwriteConfirmation(m1)])
        await fakes.queue.send(QueueStatus(items: [QueueItemDTO(meetingID: m1.rawValue, stage: "write_vault", state: "done")]))
        await model.settle()
        #expect(model.prompts.isEmpty)
        await fakes.queue.send(QueueStatus(items: [awaiting]))
        await model.settle()
        await model.refresh()
        #expect(model.prompts == [.overwriteConfirmation(m1)])
    }

    @Test func resolvingPromptFromWindowWithdrawsSystemNotice() async {
        // ウィンドウの帯から答えたら、通知センターに残った通知も取り下げる（M8）
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        let withdrawn = WithdrawLog()
        model.withdrawNotice = { id in await withdrawn.append(id) }
        model.noticePosted(.recordingTooShort(m1))
        await model.perform(.notice(.transcribeTooShort(m1)))
        await model.perform(.notice(.resolveOverwrite(m1, overwrite: true)))
        #expect(await withdrawn.items == [UserNotice.recordingTooShort(m1).id, UserNotice.overwriteConfirmation(m1).id])
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
    // MARK: - Readiness, input level, this launch's recordings, auto-selection (plan 07 Task 8)

    private let m2 = MeetingID(rawValue: "20261024-1500-c3d4")

    private func readiness(folder: Bool = true, folderPath: String = "/v", model: Readiness.Model = .installed("base"),
                           claude: Bool = true) -> Readiness {
        Readiness(outputFolder: .init(path: folderPath, available: folder), model: model,
                  claude: .init(path: claude ? "/usr/local/bin/claude" : nil, found: claude))
    }

    private func manifest(_ id: MeetingID, seconds: Double) -> Manifest {
        var m = Samples.manifest
        m.id = id
        m.endedAt = m.startedAt.addingTimeInterval(seconds)
        return m
    }

    private func start(_ fakes: FakePorts, bandDuration: Duration) async -> (AppModel, Task<Void, Never>) {
        let now = now
        let model = AppModel(ports: fakes.ports, now: { now }, timeZone: Samples.tokyo, bandDuration: bandDuration)
        let task = Task { await model.run() }
        await model.settle()
        return (model, task)
    }

    private func setRows(_ fakes: FakePorts, _ model: AppModel, _ rows: [MeetingRow]) async {
        await fakes.meetings.send(rows)
        await model.refresh()
    }

    @Test func readinessLoadsAndFollowsModelStream() async {
        let fakes = FakePorts(readiness: FakeReadinessPort(readiness(model: .none)))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.readiness.model == .none)
        await fakes.readiness.send(.downloading("base", fraction: 0.5))
        await model.settle()
        #expect(model.readiness.model == .downloading("base", fraction: 0.5))
    }

    @Test func refreshRereadsFolderAndClaudeButKeepsModel() async {
        let fakes = FakePorts(readiness: FakeReadinessPort(readiness(model: .none)))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.readiness.send(.downloading("base", fraction: 0.2))
        await model.settle()
        await fakes.readiness.setCurrent(readiness(folder: false, model: .none, claude: false))
        await model.refresh()
        #expect(model.readiness.claude.found == false)
        #expect(model.readiness.outputFolder.available == false)
        #expect(model.readiness.model == .downloading("base", fraction: 0.2))
    }

    @Test func menuBarUsesReadinessAndShortcuts() async {
        let fakes = FakePorts(readiness: FakeReadinessPort(readiness(claude: false)))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        let items = model.menuBar(now: now).items
        #expect(items.contains { if case .readinessIssue(.claude, _) = $0 { true } else { false } })
        #expect(!items.contains { if case .readinessIssue(.outputFolder, _) = $0 { true } else { false } })
        model.shortcuts.toggleRecording = "ctrl+shift+k"
        #expect(model.menuBar(now: now).items.first == .startRecording(shortcut: KeyCombo(parsing: "ctrl+shift+k")))

        // No output folder: the menu says so through the same path.
        await fakes.readiness.setCurrent(readiness(folder: false, folderPath: ""))
        await model.refresh()
        #expect(model.menuBar(now: now).items.contains(.readinessIssue(.outputFolder, title: "⚠ 保存先を作れませんでした — 設定を開く…")))
    }

    @Test func claudeFailureBandHidesTheClaudeReadinessBand() async {
        // 選択中の会議の失敗帯が「claude が見つからない」（入れ方を見る）なら、準備帯の claude 行は出さない（重複を避ける）
        let fakes = FakePorts(readiness: FakeReadinessPort(readiness(claude: false)))
        await fakes.meetings.send([MeetingRow(id: m1.rawValue, startedAt: now, state: .transcriptOnly),
                                   MeetingRow(id: m2.rawValue, startedAt: now, state: .minutesGenerated)])
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.queue.send(QueueStatus(items: [QueueItemDTO(meetingID: m1.rawValue, stage: "summarize", state: "done",
                                                                summaryFailure: "claude_not_found: ")]))
        await model.settle()
        func items() -> [ReadinessRow.Item] { model.readinessBands(home: "/Users/u").map(\.item) }
        #expect(items() == [.claude])
        model.selectedMeetingID = m2
        #expect(items() == [.claude])
        model.selectedMeetingID = m1
        #expect(items().isEmpty)
    }

    @Test func inputLevelTicksWhileRecording() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.inputLevel == nil)
        await fakes.recorder.setLevels([TrackLevel(track: .mic, peakDBFS: -20), TrackLevel(track: .system, peakDBFS: -70)])
        await fakes.recorder.send(recording())
        await model.settle()
        #expect(model.inputLevel == InputLevel(bars: 4, quiet: false))
        await fakes.recorder.send(.idle(language: .ja))
        await model.settle()
        #expect(model.inputLevel == nil)
    }

    @Test func startedAddsToRecordedThisSession() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        #expect(model.recordedThisSession.isEmpty)
        await fakes.events.send(.started(m1))
        await model.settle()
        #expect(model.recordedThisSession == [m1])
    }

    @Test func stoppedSelectsMeetingAndShowsBand() async {
        let fakes = FakePorts()
        // A long band, so a loaded full-suite run cannot see it appear and expire between polls.
        let (model, task) = await start(fakes, bandDuration: .seconds(60))
        defer { task.cancel() }
        #expect(model.selectedMeetingID == nil)
        await fakes.events.send(.stopped(manifest(m1, seconds: 252), .manual))
        await waitUntil { model.stoppedBand != nil }
        #expect(model.selectedMeetingID == m1)
        #expect(model.stoppedBand == AppModel.StoppedBand(id: m1, seconds: 252))
    }

    @Test func stoppedBandClearsAfterDuration() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes, bandDuration: .milliseconds(100))
        defer { task.cancel() }
        await fakes.events.send(.stopped(manifest(m1, seconds: 252), .manual))
        // Wait for the event to land (the band may already have come and gone under load), then for the band to clear.
        await waitUntil { model.selectedMeetingID == m1 }
        await waitUntil { model.stoppedBand == nil }
        #expect(model.selectedMeetingID == m1)
        #expect(model.stoppedBand == nil)
    }

    @Test func stoppedSelectsMeetingOverAnotherSelection() async {
        // 別の会議（失敗行など）を選んだまま録音・停止しても、止めた会議を選ぶ（GUI #8）
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        model.selectedMeetingID = m2
        await fakes.events.send(.stopped(manifest(m1, seconds: 30), .manual))
        await model.settle()
        #expect(model.selectedMeetingID == m1)
        #expect(model.stoppedBand == AppModel.StoppedBand(id: m1, seconds: 30))
    }

    @Test func stoppedKeepsSelectionWithUnsavedEdits() async {
        // 開いている議事録に未保存の編集があれば選択は変えない（帯は出る。編集を黙って捨てない）
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        model.selectedMeetingID = m2
        model.hasUnsavedEdits = { true }
        await fakes.events.send(.stopped(manifest(m1, seconds: 60), .manual))
        await model.settle()
        #expect(model.selectedMeetingID == m2)
        #expect(model.stoppedBand == AppModel.StoppedBand(id: m1, seconds: 60))
    }

    @Test func minutesReadySelectsRecordedMeetingWhenWindowOpen() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.events.send(.started(m1))
        await model.settle()
        #expect(model.minutesReady(m1, path: "/v/a.md", windowOpen: true))
        #expect(model.selectedMeetingID == m1)
        #expect(model.justSaved == AppModel.JustSaved(id: m1, path: "/v/a.md"))
    }

    @Test func minutesReadyIgnoresImportsAndClosedWindow() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.events.send(.started(m1))
        await model.settle()
        #expect(!model.minutesReady(m2, path: "/v/b.md", windowOpen: true))
        #expect(!model.minutesReady(m1, path: "/v/a.md", windowOpen: false))
        #expect(model.selectedMeetingID == nil && model.justSaved == nil)
    }

    @Test func minutesReadyDoesNotStealEditorSelection() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await setRows(fakes, model, [MeetingRow(id: m1.rawValue, startedAt: now, state: .processing),
                                     MeetingRow(id: m2.rawValue, startedAt: now, state: .minutesGenerated, filePath: "/v/b.md")])
        await fakes.events.send(.started(m1))
        await model.settle()
        model.selectedMeetingID = m2
        #expect(!model.minutesReady(m1, path: "/v/a.md", windowOpen: true))
        #expect(model.selectedMeetingID == m2 && model.justSaved == nil)

        // The selected meeting is still being processed: nothing to edit there, so the new minutes take over.
        await setRows(fakes, model, [MeetingRow(id: m1.rawValue, startedAt: now, state: .processing),
                                     MeetingRow(id: m2.rawValue, startedAt: now, state: .processing)])
        await fakes.events.send(.started(m1))
        await model.settle()
        #expect(model.minutesReady(m1, path: "/v/a.md", windowOpen: true))
        #expect(model.selectedMeetingID == m1)
    }

    @Test func minutesReadyOnlyOncePerRecording() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.events.send(.started(m1))
        await model.settle()
        #expect(model.minutesReady(m1, path: "/v/a.md", windowOpen: true))
        model.selectedMeetingID = nil
        #expect(!model.minutesReady(m1, path: "/v/a.md", windowOpen: true))
        #expect(model.selectedMeetingID == nil && !model.recordedThisSession.contains(m1))
    }

    @Test func failedOrTranscriptOnlyEndsAutoOpen() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.events.send(.started(m1))
        await fakes.events.send(.started(m2))
        await model.settle()
        await setRows(fakes, model, [MeetingRow(id: m1.rawValue, startedAt: now, state: .transcriptOnly),
                                     MeetingRow(id: m2.rawValue, startedAt: now, state: .failed)])
        #expect(model.recordedThisSession.isEmpty)
        #expect(!model.minutesReady(m1, path: "/v/a.md", windowOpen: true))
        #expect(model.selectedMeetingID == nil)
    }

    @Test func justSavedClearsOnReselect() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        await fakes.events.send(.started(m1))
        await model.settle()
        #expect(model.minutesReady(m1, path: "/v/a.md", windowOpen: true))
        model.selectedMeetingID = m1
        #expect(model.justSaved == AppModel.JustSaved(id: m1, path: "/v/a.md"))
        model.selectedMeetingID = m2
        #expect(model.justSaved == nil)
        model.selectedMeetingID = m1
        #expect(model.justSaved == nil)
    }

    @Test func tooShortPromptsFollowRows() async {
        let fakes = FakePorts()
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        let withdrawn = WithdrawLog()
        model.withdrawNotice = { id in await withdrawn.append(id) }
        await setRows(fakes, model, [MeetingRow(id: m1.rawValue, startedAt: now, state: .tooShort)])
        #expect(model.prompts == [.recordingTooShort(m1)])
        model.noticePosted(.recordingTooShort(m1))
        #expect(model.prompts == [.recordingTooShort(m1)])
        await setRows(fakes, model, [MeetingRow(id: m1.rawValue, startedAt: now, state: .processing)])
        #expect(model.prompts.isEmpty)
        await waitUntil { await !withdrawn.items.isEmpty }
        #expect(await withdrawn.items == ["meeting.tooShort.\(m1.rawValue)"])
    }

    @Test func readinessActions() async {
        let fakes = FakePorts(readiness: FakeReadinessPort(readiness(claude: false)))
        let (model, task) = await start(fakes)
        defer { task.cancel() }
        let found = Readiness.Claude(path: "/opt/homebrew/bin/claude", found: true)
        await fakes.readiness.setRedetectResult(found)
        await model.perform(.redetectClaude)
        #expect(await fakes.readiness.calls == ["redetectClaude"])
        #expect(model.readiness.claude == found)

        await model.perform(.redetectClaudeAndRerun(m1))
        #expect(await fakes.queue.calls == ["retry(\(m1.rawValue))"])
        #expect(model.lastError == nil)

        await fakes.readiness.setRedetectResult(.init(path: nil, found: false))
        await model.perform(.redetectClaudeAndRerun(m1))
        #expect(model.lastError == "Claude Code（claude）が見つかりません")
        #expect(await fakes.queue.calls == ["retry(\(m1.rawValue))"])
        #expect(model.readiness.claude.found == false)

        await model.perform(.retryModelDownload)
        await model.perform(.installGuide)
        #expect(await fakes.readiness.calls.suffix(2) == ["retryModelDownload", "installGuide"])
    }
}

private actor WithdrawLog {
    var items: [String] = []
    func append(_ s: String) { items.append(s) }
}
