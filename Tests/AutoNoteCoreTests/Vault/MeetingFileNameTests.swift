import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test func fileNames() {
    #expect(MeetingFileName.titled(start: Samples.start, title: "プロジェクト定例", timeZone: Samples.tokyo) == "2026-10-24_1400_プロジェクト定例.md")
    #expect(MeetingFileName.untitled(start: Samples.start, timeZone: Samples.tokyo) == "2026-10-24_140000.md")
    #expect(MeetingFileName.yearFolder(start: Samples.start, timeZone: Samples.tokyo) == "2026")
    #expect(MeetingFileName.isUntitled("2026-10-24_140000-2.md")); #expect(!MeetingFileName.isUntitled("2026-10-24_1400_x.md"))
    #expect(MeetingFileName.unique("x.md") { ["x.md", "x-2.md"].contains($0) } == "x-3.md")
}

@Test func sanitizeReplacesForbiddenCharacters() {
    #expect(MeetingFileName.sanitize(#"A/B:C|D#E^F[G]H?*"<>\"#) == "A／B：C｜D＃E＾F［G］H？＊”＜＞＼")
    #expect(MeetingFileName.sanitize("  ..改行\nあり.. ") == "改行 あり"); #expect(MeetingFileName.sanitize("") == "無題")
    #expect(MeetingFileName.sanitize(String(repeating: "あ", count: 61)).count == 60)
}
