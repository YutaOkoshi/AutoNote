import Testing
import Foundation
@testable import AutoNoteCore

private let e1 = IndexEntry(meetingID: .init(rawValue: "20261024-1400-a1b2"), date: "2026-10-24", start: "14:00", title: "プロジェクト定例", durationMinutes: 62,
                            firstLine: "リリースは来週に決定", status: "minutes_generated", linkPath: "2026/2026-10-24_1400_プロジェクト定例")

@Test func indexHeadingGuideAndRowsNewestFirst() {
    #expect(IndexFile.render([]).hasPrefix("# 会議一覧\n\n> **Claude Code への案内**")); #expect(IndexFile.guide.split(separator: "\n").count == 5)
    var e2 = e1; e2.date = "2026-10-25"; e2.start = "09:30"; e2.durationMinutes = nil; e2.linkPath = "2026/2026-10-25_093015"
    #expect(IndexFile.render([e1, e2]).split(separator: "\n").filter { $0.hasPrefix("| 2026") } == [
        "| 2026-10-25 | 09:30 | プロジェクト定例 | — | リリースは来週に決定 | [[2026/2026-10-25_093015]] |",
        "| 2026-10-24 | 14:00 | プロジェクト定例 | 62 分 | リリースは来週に決定 | [[2026/2026-10-24_1400_プロジェクト定例]] |"])
}

@Test func indexEscapesPipeInTitle() { var e = e1; e.title = "A|B"; #expect(IndexFile.render([e]).contains("| A\\|B |")) }

@Test func indexTieBreaksByLinkPathDescendingAndEndsWithNewline() {
    var a = e1; a.linkPath = "2026/a"; var b = e1; b.linkPath = "2026/b"
    let rows = IndexFile.render([a, b]).split(separator: "\n").filter { $0.hasPrefix("| 2026") }
    #expect(rows.first?.hasSuffix("[[2026/b]] |") == true)
    #expect(IndexFile.render([a]).hasSuffix("|\n")); #expect(IndexFile.render([]).hasSuffix("|---|---|---|---|---|---|\n"))
}

@Test func frontmatterParseUnquotes() {
    #expect(Frontmatter.parse("---\ntitle: \"Q3: \\\"予算\\\"\"\nautonote_id: x\n---\n# h\n") == ["title": "Q3: \"予算\"", "autonote_id": "x"])
    #expect(Frontmatter.parse("# no frontmatter\n") == nil)
    #expect(Frontmatter.parse("---\ntitle: x\n") == nil)
    #expect(Frontmatter.parse("---\ntitle: \"a\\\\b\"\n---\n") == ["title": "a\\b"])
}
