import Foundation
import Testing
@testable import AutoNoteCore

@Suite struct IPCProtocolTests {
    private func line(_ v: some Encodable) throws -> String { String(decoding: try IPCCodec.encode(v), as: UTF8.self) }

    @Test func commandsMatchSpecTable() {
        #expect(IPCCommand.allCases.map(\.rawValue) == ["start", "stop", "pause", "resume", "bookmark", "status", "list", "latest", "import", "regenerate", "automations.list", "automations.run"])
    }

    @Test func decodesSnakeCaseRequest() throws {
        let r = try IPCCodec.decodeRequest(Data(#"{"cmd":"regenerate","args":{"meeting_id":"20261024-1400-a1b2"},"id":7}"#.utf8))
        #expect(r == IPCRequest(cmd: .regenerate, args: IPCArgs(meetingID: "20261024-1400-a1b2"), id: 7))
    }

    @Test func requestRoundTripForEveryCommand() throws {
        let args = IPCArgs(lang: .ja, note: "メモ", since: "2026-10-01", open: true, file: "/tmp/a.m4a", meetingID: "20261024-1400-a1b2", name: "notify")
        for cmd in IPCCommand.allCases {
            for a in [IPCArgs(), args] {
                let req = IPCRequest(cmd: cmd, args: a, id: 11)
                let data = try IPCCodec.encode(req)
                #expect(try IPCCodec.decodeRequest(data) == req)
            }
        }
    }

    @Test func encodedLineIsOneLine() throws {
        let data = try IPCCodec.encode(IPCRequest(cmd: .bookmark, args: IPCArgs(note: "一行目\n二行目"), id: 1))
        #expect(data.last == 0x0A)
        #expect(!data.dropLast().contains(0x0A))
    }

    @Test func unknownCommandKeepsID() {
        let explode = #"{"cmd":"explode","args":{},"id":4}"#
        #expect(throws: IPCDecodeFailure(id: 4, error: IPCError(code: .unknownCommand, message: "知らないコマンドです: explode"))) { try IPCCodec.decodeRequest(Data(explode.utf8)) }
    }

    @Test func malformedLineIsBadRequestWithoutID() {
        do {
            _ = try IPCCodec.decodeRequest(Data("not json".utf8))
            Issue.record("expected failure")
        } catch {
            #expect(error.id == nil)
            #expect(error.error.code == .badRequest)
        }
    }

    @Test func badRequestKeepsReadableID() {
        do {
            _ = try IPCCodec.decodeRequest(Data(#"{"cmd":"start","args":{"lang":"xx"},"id":9}"#.utf8))
            Issue.record("expected failure")
        } catch {
            #expect(error.id == 9)
            #expect(error.error.code == .badRequest)
        }
    }

    @Test func errorResponseShape() throws {
        let s = try line(IPCResponse.failure(3, IPCError(code: .notRecording, message: "録音中ではありません")))
        #expect(s == #"{"error":{"code":"not_recording","message":"録音中ではありません"},"id":3,"ok":false}"# + "\n")
    }

    @Test func lineBufferSplitsAcrossChunks() throws {
        var b = LineBuffer()
        #expect(try b.append(Data(#"{"a""#.utf8)).isEmpty)
        let lines = try b.append(Data(":1}\n{}\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, "{}"])
    }

    @Test func lineBufferRejectsOverlongLine() {
        var b = LineBuffer()
        #expect(throws: IPCError.self) { try b.append(Data(repeating: 0x61, count: LineBuffer.maxLineBytes + 1)) }
        // the buffer was cleared, so a fresh line works again
        #expect((try? b.append(Data("{}\n".utf8)))?.count == 1)
    }

    @Test func stageLabels() {
        #expect(StageLabel.text(stage: "transcribe", progress: 0.42) == "文字起こし中 42%")
        #expect(StageLabel.text(stage: "summarize", progress: nil) == "議事録生成中")
        #expect(StageLabel.text(stage: "write_vault", progress: nil) == "Vault に書き出し中")
        #expect(StageLabel.text(stage: "update_index", progress: nil) == "一覧を更新中")
        #expect(StageLabel.text(stage: "automations", progress: nil) == "Automations 実行中")
        #expect(StageLabel.text(stage: "mystery", progress: nil) == "mystery")
    }

    @Test func meetingIDIsSnakeCaseOnTheWire() throws {
        #expect(try line(IPCArgs(meetingID: "m1")).contains(#""meeting_id":"m1""#))
        #expect(try line(IPCResult(meetingID: "m1")).contains(#""meeting_id":"m1""#))
        #expect(try line(RecorderStatusDTO(state: "recording", meetingID: "m1")).contains(#""meeting_id":"m1""#))
        #expect(try line(QueueItemDTO(meetingID: "m1", stage: "summarize", state: "running", label: "x", awaitingConfirmation: false, generation: 1)).contains(#""meeting_id":"m1""#))
    }

    @Test func queueItemNotBeforeRoundTripsAndNilIsOmitted() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000.25)
        let item = QueueItemDTO(meetingID: "m1", stage: "summarize", state: "waiting", label: "x", awaitingConfirmation: false, generation: 2, notBefore: when)
        #expect(try IPCCodec.decodeResponse(IPCCodec.encode(IPCResponse.success(1, IPCResult(status: StatusResult(recorder: RecorderStatusDTO(state: "idle"), queue: [item], outputFolderAvailable: true))))).result?.status?.queue == [item])
        let s = try line(QueueItemDTO(meetingID: "m1", stage: "s", state: "running", label: "x", awaitingConfirmation: false, generation: 0))
        #expect(!s.contains("not_before") && !s.contains("progress") && !s.contains("message"))
    }

    @Test func responseRoundTripWithMeetingsAndAutomations() throws {
        let row = MeetingRow(id: "m1", title: "定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000.5), durationMinutes: 30, state: .minutesGenerated, filePath: "/v/a.md")
        let auto = AutomationSummary(name: "notify", on: .minutesGenerated, enabled: true, isRunnable: false, problem: "x")
        let res = IPCResponse.success(5, IPCResult(meetings: [row], bookmark: Bookmark(at: TimelineTime(seconds: 3), note: "n"), automations: [auto]))
        let back = try IPCCodec.decodeResponse(IPCCodec.encode(res))
        #expect(back == res)
        #expect(try line(res).contains(#""state":"minutes_generated""#))
    }

    @Test func rowStateRawValues() {
        #expect(MeetingRowState.tooShort.rawValue == "too_short" && MeetingRowState.transcriptOnly.rawValue == "transcript_only")
    }
}
