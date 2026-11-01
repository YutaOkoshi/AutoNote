import Testing
import Foundation
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct MergePreviewTests {
    private func recording(_ suffix: String, start: Double, seconds: Double) -> Manifest {
        var m = Samples.manifest
        m.id = MeetingID(rawValue: "20261024-1400-\(suffix)")
        m.startedAt = Samples.start.addingTimeInterval(start)
        m.endedAt = Samples.start.addingTimeInterval(start + seconds)
        m.status = .transcriptOnly
        return m
    }

    @Test func summarisesTheCombinedMeeting() throws {
        // The SPEC example: 0–88 s, 90–268 s, 410–2860 s from 14:00:00 in Tokyo.
        let manifests = [recording("0003", start: 410, seconds: 2450), recording("0001", start: 0, seconds: 88),
                         recording("0002", start: 90, seconds: 178)]
        let preview = try MergePreview.make(manifests)
        #expect(preview.count == 3)
        #expect(preview.startedAt == Samples.start)
        #expect(preview.endedAt == Samples.start.addingTimeInterval(2860))
        #expect(preview.gapSeconds == 144)
        #expect(MergePreview.title == "1 つの会議に統合しますか？")
        #expect(preview.message(timeZone: Samples.tokyo) == """
            3 件の録音を 1 つの会議にまとめ、文字起こしからやり直します。
            開始 2026/10/24 14:00:00 → 終了 14:47:40（隙間の合計 2 分 24 秒）
            元の会議は一覧と Vault から外れます（録音ファイルは残ります）。
            """)
    }

    @Test func endOnAnotherDayShowsTheDate() throws {
        let preview = try MergePreview.make([recording("0001", start: 0, seconds: 60),
                                             recording("0002", start: 36_000, seconds: 60)])
        #expect(preview.message(timeZone: Samples.tokyo).contains("開始 2026/10/24 14:00:00 → 終了 2026/10/25 00:01:00（隙間の合計 9 時間 59 分）"))
    }

    @Test func refusesWithTheSameReasonsAsTheMerge() {
        var imported = recording("0002", start: 90, seconds: 10)
        imported.source = .imported
        #expect(throws: CombineError.notLive(imported.id)) { try MergePreview.make([recording("0001", start: 0, seconds: 10), imported]) }
        // A meeting with an active job counts as processing; failed and done jobs do not.
        let queue = QueueStatus(items: [
            QueueItemDTO(meetingID: "20261024-1400-0001", stage: "write_vault", state: "failed", label: "", awaitingConfirmation: false, generation: 1),
            QueueItemDTO(meetingID: "20261024-1400-0002", stage: "transcribe", state: "pending", label: "", awaitingConfirmation: false, generation: 1),
        ])
        #expect(queue.activeMeetingIDs == [MeetingID(rawValue: "20261024-1400-0002")])
        #expect(throws: CombineError.processing(MeetingID(rawValue: "20261024-1400-0002"))) {
            try MergePreview.make([recording("0001", start: 0, seconds: 10), recording("0002", start: 20, seconds: 10)], queue: queue)
        }
    }
}
