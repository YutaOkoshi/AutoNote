import Testing
import Foundation
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct MeetingListBuilderTests {
    let folder = URL(filePath: "/tmp/Vault/Meetings", directoryHint: .isDirectory)

    func entry(_ id: String, date: String = "2026-10-24", start: String = "14:00", title: String = "定例",
               status: String = "minutes_generated", linkPath: String = "2026/2026-10-24_1400_定例") -> IndexEntry {
        IndexEntry(meetingID: MeetingID(rawValue: id), date: date, start: start, title: title, durationMinutes: 62,
                   firstLine: "リリースは来週", status: status, linkPath: linkPath)
    }

    func manifest(_ id: String, status: MeetingStatus, title: String? = nil, start: Date = Samples.start) -> Manifest {
        var m = Samples.manifest
        m.id = MeetingID(rawValue: id)
        m.status = status
        m.title = title
        m.startedAt = start
        return m
    }

    @Test func indexOnlyEntryAppears() throws {
        let rows = MeetingListBuilder.build(index: [entry("20261024-1400-a1b2")], manifests: [], queue: .empty,
                                            outputFolder: folder, timeZone: Samples.tokyo)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.state == .minutesGenerated)
        #expect(row.filePath == "/tmp/Vault/Meetings/2026/2026-10-24_1400_定例.md")
        #expect(row.startedAt == Samples.start)  // 2026-10-24 14:00 in Tokyo
        #expect(row.durationMinutes == 62)
        #expect(row.summaryFirstLine == "リリースは来週")
    }

    @Test func durationSecondsFromManifest() throws {
        var m = manifest("20261024-1400-a1b2", status: .recording)
        m.endedAt = m.startedAt + 32.7   // duration 32.7 s
        let rows = MeetingListBuilder.build(index: [entry("20261023-0900-c3d4", date: "2026-10-23", start: "09:00")], manifests: [m],
                                            queue: .empty, outputFolder: folder, timeZone: Samples.tokyo)
        #expect(rows.first { $0.id == "20261024-1400-a1b2" }?.durationSeconds == 32)
        let indexOnly = try #require(rows.first { $0.id == "20261023-0900-c3d4" })
        #expect(indexOnly.durationSeconds == nil)
    }

    @Test func manifestOnlyRecordingAppears() throws {
        let rows = MeetingListBuilder.build(index: [], manifests: [manifest("20261024-1400-a1b2", status: .recording)],
                                            queue: .empty, outputFolder: folder)
        let row = try #require(rows.first)
        #expect(row.state == .recording)
        #expect(row.title == "（無題）")
        #expect(row.filePath == nil)
    }

    @Test func noteOutsideOutputFolderKeepsTitleAndPath() throws {
        // 保存先を変えたあと: 今の保存先に無い会議は、最後に書いた議事録のタイトルとパスを使う（ファイルがある間だけ）
        var m = manifest("20261024-1400-a1b2", status: .minutesGenerated)
        m.notePath = "/Users/u/Documents/AutoNote/2026/2026-10-24_1400_定例.md"
        m.noteTitle = "定例"
        let kept = try #require(MeetingListBuilder.build(index: [], manifests: [m], queue: .empty, outputFolder: folder,
                                                         fileExists: { _ in true }).first)
        #expect(kept.title == "定例")
        #expect(kept.filePath == m.notePath)
        let gone = try #require(MeetingListBuilder.build(index: [], manifests: [m], queue: .empty, outputFolder: folder,
                                                         fileExists: { _ in false }).first)
        #expect(gone.filePath == nil)
        // The output folder's own note wins.
        let indexed = try #require(MeetingListBuilder.build(index: [entry("20261024-1400-a1b2", title: "Vault のタイトル")],
                                                            manifests: [m], queue: .empty, outputFolder: folder,
                                                            fileExists: { _ in true }).first)
        #expect(indexed.title == "Vault のタイトル")
        #expect(indexed.filePath == "/tmp/Vault/Meetings/2026/2026-10-24_1400_定例.md")
    }

    @Test func indexTitleWins() throws {
        let rows = MeetingListBuilder.build(index: [entry("20261024-1400-a1b2", title: "Vault のタイトル")],
                                            manifests: [manifest("20261024-1400-a1b2", status: .minutesGenerated, title: "manifest のタイトル")],
                                            queue: .empty, outputFolder: folder)
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Vault のタイトル")
    }

    @Test func runningJobOverridesState() throws {
        let queue = QueueStatus(items: [QueueItemDTO(meetingID: "20261024-1400-a1b2", stage: "transcribe", state: "running",
                                                     progress: 0.42, label: StageLabel.text(stage: "transcribe", progress: 0.42))],
                                pausedForRecording: false)
        let rows = MeetingListBuilder.build(index: [entry("20261024-1400-a1b2")],
                                            manifests: [manifest("20261024-1400-a1b2", status: .minutesGenerated)],
                                            queue: queue, outputFolder: folder)
        #expect(rows.first?.state == .processing)
        #expect(rows.first?.progressLabel == "文字起こし中 42%")
    }

    @Test func indexStatusMapping() {
        let rows = MeetingListBuilder.build(index: [
            entry("20261024-1400-0001", status: "transcript_only"),
            entry("20261024-1400-0002", status: "failed"),
            entry("20261024-1400-0003", status: "minutes_generated"),
            entry("20261024-1400-0004", status: "something_else"),
        ], manifests: [], queue: .empty, outputFolder: folder)
        let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
        #expect(states["20261024-1400-0001"] == .transcriptOnly)
        #expect(states["20261024-1400-0002"] == .failed)
        #expect(states["20261024-1400-0003"] == .minutesGenerated)
        #expect(states["20261024-1400-0004"] == .minutesGenerated)
    }

    @Test func tooShortAndSilenceWarning() throws {
        var m = manifest("20261024-1400-a1b2", status: .tooShort)
        m.silenceWarning = true
        let row = try #require(MeetingListBuilder.build(index: [], manifests: [m], queue: .empty, outputFolder: nil).first)
        #expect(row.state == .tooShort)
        #expect(row.silenceWarning)
    }

    /// X28: in-flight manifest statuses become `.processing`, labelled from the queue or "処理待ち".
    @Test func processingStatusesFromManifest() {
        let rows = MeetingListBuilder.build(index: [], manifests: [
            manifest("20261024-1400-0001", status: .recorded),
            manifest("20261024-1400-0002", status: .generating),
        ], queue: QueueStatus(items: [QueueItemDTO(meetingID: "20261024-1400-0002", stage: "summarize", state: "pending",
                                                    label: "議事録生成中")], pausedForRecording: false),
           outputFolder: nil)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["20261024-1400-0001"]?.state == .processing)
        #expect(byID["20261024-1400-0001"]?.progressLabel == "処理待ち")
        #expect(byID["20261024-1400-0002"]?.state == .processing)
        #expect(byID["20261024-1400-0002"]?.progressLabel == "議事録生成中")
    }

    @Test func newestFirstAndSinceFilter() throws {
        let rows = MeetingListBuilder.build(index: [
            entry("20260930-0900-0001", date: "2026-09-30", start: "23:59", linkPath: "a"),
            entry("20261001-0000-0002", date: "2026-10-01", start: "00:00", linkPath: "b"),
            entry("20261024-1400-0003", date: "2026-10-24", start: "14:00", linkPath: "c"),
        ], manifests: [], queue: .empty, outputFolder: folder, timeZone: Samples.tokyo)
        #expect(rows.map(\.id) == ["20261024-1400-0003", "20261001-0000-0002", "20260930-0900-0001"])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Samples.tokyo
        let filtered = try MeetingListBuilder.filter(rows, since: "2026-10-01", calendar: calendar)
        #expect(filtered.map(\.id) == ["20261024-1400-0003", "20261001-0000-0002"])
        #expect(throws: AppCommandError.invalid("日付は YYYY-MM-DD で指定してください: 10/01")) {
            try MeetingListBuilder.filter(rows, since: "10/01", calendar: calendar)
        }
    }
}
