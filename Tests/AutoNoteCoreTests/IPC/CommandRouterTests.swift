import Foundation
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct CommandRouterTests {
    private let now = Samples.start
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Samples.tokyo
        return c
    }

    private func router(_ fakes: FakePorts) -> CommandRouter {
        let now = now
        return CommandRouter(ports: fakes.ports, now: { now }, calendar: calendar)
    }

    private func req(_ cmd: IPCCommand, _ args: IPCArgs = IPCArgs()) -> IPCRequest { IPCRequest(cmd: cmd, args: args, id: 1) }

    @Test func statusIdle() async {
        let r = await router(FakePorts()).handle(IPCRequest(cmd: .status, args: IPCArgs(), id: 1))
        #expect(r.ok && r.result?.status?.recorder.state == "idle" && r.result?.status?.queue == [])
    }

    @Test func statusRecordingElapsed() async {
        let fakes = FakePorts()
        await fakes.recorder.send(RecorderSnapshot(state: .recording, meetingID: MeetingID(rawValue: "m1"),
                                                   startedAt: now.addingTimeInterval(-754), deviceName: "Jabra", language: .ja))
        let s = await router(fakes).handle(req(.status)).result?.status
        #expect(s?.recorder.state == "recording" && s?.recorder.elapsedSeconds == 754 && s?.recorder.device == "Jabra")
        // The port's timeline position wins over now - startedAt (X25).
        await fakes.recorder.setElapsed(TimelineTime(seconds: 700))
        let s2 = await router(fakes).handle(req(.status)).result?.status
        #expect(s2?.recorder.elapsedSeconds == 700)
        // Recording without a meeting id has no elapsed time.
        await fakes.recorder.send(RecorderSnapshot(state: .recording, startedAt: now.addingTimeInterval(-5), language: .ja))
        let s3 = await router(fakes).handle(req(.status)).result?.status
        #expect(s3?.recorder.elapsedSeconds == nil)
    }

    @Test func statusCountdownRemaining() async {
        let fakes = FakePorts()
        await fakes.recorder.send(RecorderSnapshot(state: .countdown, deadline: now.addingTimeInterval(3), language: .ja))
        let s = await router(fakes).handle(req(.status)).result?.status
        #expect(s?.recorder.state == "countdown" && s?.recorder.secondsRemaining == 3)
    }

    @Test func statusHidesDoneQueueItemsAndReportsFolder() async {
        let fakes = FakePorts(outputFolder: FakeOutputFolderPort(available: false))
        await fakes.queue.send(QueueStatus(items: [
            QueueItemDTO(meetingID: "a", stage: "transcribe", state: "running", progress: 0.5, label: "文字起こし中 50%"),
            QueueItemDTO(meetingID: "b", stage: "summarize", state: "done", label: "議事録生成中", summaryFailure: "timeout"),
        ]))
        let s = await router(fakes).handle(req(.status)).result?.status
        #expect(s?.queue.map(\.meetingID) == ["a"] && s?.queue.first?.label == "文字起こし中 50%" && s?.outputFolderAvailable == false)
    }

    @Test func bookmarkWhileIdle() async {
        let r = await router(FakePorts()).handle(IPCRequest(cmd: .bookmark, args: IPCArgs(note: "x"), id: 2))
        #expect(!r.ok && r.error == IPCError(code: .notRecording, message: "録音中ではありません"))
        #expect(r.id == 2)
    }

    @Test func bookmarkWhileRecordingReturnsIt() async {
        let fakes = FakePorts()
        await fakes.recorder.send(RecorderSnapshot(state: .recording, meetingID: MeetingID(rawValue: "m1"), language: .ja))
        await fakes.recorder.setElapsed(TimelineTime(seconds: 12))
        let r = await router(fakes).handle(req(.bookmark, IPCArgs(note: "要確認")))
        #expect(r.ok && r.result?.bookmark == Bookmark(at: TimelineTime(seconds: 12), note: "要確認"))
    }

    @Test func startPassesLanguage() async {
        let fakes = FakePorts()
        let r = await router(fakes).handle(req(.start, IPCArgs(lang: .en)))
        #expect(r.ok)
        #expect(await fakes.recorder.calls == ["start(en)"])
        // Starting again maps to already_recording.
        let again = await router(fakes).handle(req(.start))
        #expect(again.error == IPCError(code: .alreadyRecording, message: "すでに録音中です"))
    }

    @Test func stopPauseResumeForwardAndMapErrors() async {
        let fakes = FakePorts()
        let r = await router(fakes).handle(req(.stop))
        #expect(r.error == IPCError(code: .notRecording, message: "録音中ではありません"))
        _ = await router(fakes).handle(req(.start))
        #expect(await router(fakes).handle(req(.pause)).ok)
        #expect(await router(fakes).handle(req(.resume)).ok)
        #expect(await router(fakes).handle(req(.stop)).ok)
        #expect(await fakes.recorder.calls == ["stop", "start(nil)", "pause", "resume", "stop"])
    }

    @Test func listSinceAndInvalidSince() async {
        let old = MeetingRow(id: "old", startedAt: now.addingTimeInterval(-40 * 86400))
        let recent = MeetingRow(id: "new", startedAt: now)
        let fakes = FakePorts(meetings: FakeMeetingsPort(rows: [recent, old]))
        let all = await router(fakes).handle(req(.list))
        #expect(all.result?.meetings?.map(\.id) == ["new", "old"])
        let filtered = await router(fakes).handle(req(.list, IPCArgs(since: "2026-10-01")))
        #expect(filtered.result?.meetings?.map(\.id) == ["new"])
        let bad = await router(fakes).handle(req(.list, IPCArgs(since: "10/01")))
        #expect(!bad.ok && bad.error?.code == .invalidArgs)
    }

    @Test func latestNone() async {
        let r = await router(FakePorts()).handle(req(.latest))
        #expect(r.error == IPCError(code: .notFound, message: "議事録がまだありません"))
    }

    @Test func latestOpenCallsOpener() async {
        let fakes = FakePorts(meetings: FakeMeetingsPort(rows: [MeetingRow(id: "m", filePath: "/vault/m.md")]))
        let plain = await router(fakes).handle(req(.latest))
        #expect(plain.result?.path == "/vault/m.md")
        #expect(await fakes.opener.opened.isEmpty)
        let opened = await router(fakes).handle(req(.latest, IPCArgs(open: true)))
        #expect(opened.ok && opened.result?.path == "/vault/m.md")
        #expect(await fakes.opener.opened == [URL(filePath: "/vault/m.md")])
    }

    @Test func importNeedsAbsoluteExistingFile() async throws {
        let fakes = FakePorts()
        let relative = await router(fakes).handle(req(.import, IPCArgs(file: "rec.m4a")))
        #expect(relative.error == IPCError(code: .invalidArgs, message: "ファイルは絶対パスで渡してください"))
        let missing = "/nonexistent-autonote/録音 1.m4a"
        let gone = await router(fakes).handle(req(.import, IPCArgs(file: missing)))
        #expect(gone.error == IPCError(code: .notFound, message: "ファイルがありません: \(missing)"))
        // Spaces and Unicode in an existing file are fine.
        let dir = FileManager.default.temporaryDirectory.appending(path: "cr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "会議 録音.m4a")
        try Data([0]).write(to: file)
        let ok = await router(fakes).handle(req(.import, IPCArgs(file: file.path)))
        #expect(ok.ok && ok.result?.meetingID == "20261024-1400-0000")
        #expect(await fakes.meetings.calls == ["importAudio(\(file.path))"])
    }

    @Test func regenerateUnknown() async {
        let fakes = FakePorts()
        await fakes.queue.setNextError(.notFound("会議が見つかりません: x"))
        let r = await router(fakes).handle(req(.regenerate, IPCArgs(meetingID: "x")))
        #expect(r.error == IPCError(code: .notFound, message: "会議が見つかりません: x"))
        let missingID = await router(fakes).handle(req(.regenerate))
        #expect(missingID.error?.code == .invalidArgs)
        let ok = await router(fakes).handle(req(.regenerate, IPCArgs(meetingID: "y")))
        #expect(ok.ok)
        #expect(await fakes.queue.calls == ["regenerate(x)", "regenerate(y)"])
    }

    @Test func automationsListAndRun() async {
        let list = [AutomationSummary(name: "a", enabled: true, isRunnable: true), AutomationSummary(name: "b")]
        let fakes = FakePorts(automations: FakeAutomationsPort(summaries: list))
        let l = await router(fakes).handle(req(.automationsList))
        #expect(l.result?.automations?.count == 2)
        let bad = await router(fakes).handle(req(.automationsRun))
        #expect(bad.error == IPCError(code: .invalidArgs, message: "Automation の名前と会議 ID が要ります"))
        let run = await router(fakes).handle(req(.automationsRun, IPCArgs(meetingID: "m1", name: "a")))
        #expect(run.ok && run.result?.run?.name == "a" && run.result?.run?.meetingID == "m1")
    }

    @Test func unexpectedErrorIsFailed() async {
        struct Boom: Error {}
        #expect(CommandRouter.ipcError(Boom()).code == .failed)
        #expect(CommandRouter.ipcError(AppCommandError.failed("壊れた")) == IPCError(code: .failed, message: "壊れた"))
        #expect(CommandRouter.ipcError(AppCommandError.invalid("x")) == IPCError(code: .invalidArgs, message: "x"))
    }
}
