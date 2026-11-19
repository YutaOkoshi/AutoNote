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

/// Lead 差し戻し 2-5: an English title at the schema's limit (60, spaces and punctuation included) keeps every
/// character in the file name, a forbidden character is replaced (never dropped), and the note's frontmatter quotes it.
@Test func aLongEnglishTitleSurvivesTheFileNameAndTheNote() {
    let title = "Q4 Planning: Tenant Migration/Rollback Review & On-call Plan"
    #expect(title.count == 60 && title.count == MinutesSchema.titleMaxLength(.en))
    let name = MeetingFileName.titled(start: Samples.start, title: title, timeZone: Samples.tokyo)
    #expect(name == "2026-10-24_1400_Q4 Planning： Tenant Migration／Rollback Review & On-call Plan.md")
    var minutes = Samples.minutes
    minutes.title = title
    let document = MeetingDocument(manifest: Samples.manifest, transcript: Transcript(utterances: [], engine: "whisper.cpp", language: .en),
                                   minutes: minutes, frontmatter: .init(text: FrontmatterTemplate.defaultText),
                                   appVersion: "0.6.0", timeZone: Samples.tokyo)
    #expect(document.preferredFileName == name)
    #expect(document.render().contains(#"title: "Q4 Planning: Tenant Migration/Rollback Review & On-call Plan""#))
    // Longer than the limit (never from the schema, but from an edit): cut at 60 without a trailing space.
    #expect(MeetingFileName.sanitize(title + " and more").count <= 60)
    #expect(!MeetingFileName.sanitize(title + " and more").hasSuffix(" "))
}
