import Testing
import Foundation
import AutoNoteTestSupport
@testable import AutoNoteCore

private let e1 = IndexEntry(meetingID: .init(rawValue: "20261024-1400-a1b2"), date: "2026-10-24", start: "14:00", title: "プロジェクト定例", durationMinutes: 62,
                            firstLine: "リリースは来週に決定", status: "minutes_generated", linkPath: "2026/2026-10-24_1400_プロジェクト定例")

@Test func scannerReadsMeetingFilesOnly() throws {
    let v = try TemporaryDirectory.make(); let fm = FileManager.default
    let d = MeetingDocument(manifest: Samples.manifest, transcript: Transcript(utterances: [], engine: "e", language: .ja), minutes: Samples.minutes,
                            frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.1.0", timeZone: Samples.tokyo)
    for dir in ["2026", "notes", "_autonote", ".hidden"] { try fm.createDirectory(at: v.appending(path: dir), withIntermediateDirectories: true) }
    for (path, text) in [("2026/\(d.preferredFileName)", d.render()), ("notes/own.md", "# 自分のメモ\n"), ("_autonote/copy.md", d.render()),
                         (".hidden/copy.md", d.render()), ("2026/other.txt", d.render()), ("_index.md", "# 会議一覧\n")] { try text.write(to: v.appending(path: path), atomically: true, encoding: .utf8) }
    #expect(try VaultScanner.scan(outputFolder: v) == [e1])
    #expect(try VaultScanner.locate(Samples.manifest.id, in: v).map(\.lastPathComponent) == ["2026-10-24_1400_プロジェクト定例.md"])
}

@Test func scannerHandlesTranscriptOnlyAndDuplicates() throws {
    let v = try TemporaryDirectory.make(); let fm = FileManager.default
    var m = Samples.manifest; m.status = .transcriptOnly
    let d = MeetingDocument(manifest: m, transcript: Transcript(utterances: [], engine: "e", language: .ja), minutes: nil,
                            frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.1.0", timeZone: Samples.tokyo)
    try fm.createDirectory(at: v.appending(path: "2026"), withIntermediateDirectories: true)
    try d.render().write(to: v.appending(path: "2026/\(d.preferredFileName)"), atomically: true, encoding: .utf8)
    try d.render().write(to: v.appending(path: "2026/copy.md"), atomically: true, encoding: .utf8)
    let entries = try VaultScanner.scan(outputFolder: v)
    #expect(entries.count == 2); #expect(entries.allSatisfy { $0.firstLine == "（議事録未生成）" })
    #expect(try VaultScanner.locate(m.id, in: v).count == 2)
    #expect(try VaultScanner.locate(.init(rawValue: "nope"), in: v).isEmpty)
}
