import Testing
import Foundation
import AutoNoteTestSupport
@testable import AutoNoteCore

private func doc(_ minutes: MinutesOutput?, status: MeetingStatus = .minutesGenerated, title: String? = nil) -> MeetingDocument {
    var m = Samples.manifest; m.status = status; m.title = title; m.bookmarks = [Bookmark(at: .init(seconds: 1215), note: "大事")]
    return MeetingDocument(manifest: m, transcript: Transcript(utterances: [u(5, .me, "はじめます"), u(754, .other, "来週出します")], engine: "whisper.cpp large-v3-turbo", language: .ja),
                           minutes: minutes, frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.1.0", timeZone: Samples.tokyo)
}

@Test func documentHasSectionsInOrder() throws {
    let s = doc(Samples.minutes).render()
    let pos = try ["# プロジェクト定例", "## 3行要約", "## 決定事項", "## 議題", "## Next Action", "## ブックマーク", "## 文字起こし"].map { try #require(s.range(of: "\n\($0)\n")).lowerBound }
    #expect(pos == pos.sorted()); #expect(s.contains("- [[#^t00-12-34|20:15]] 大事"))
    #expect(s.contains("| ドキュメント更新 | 自分 | 10/31 | [[#^t00-12-34\\|40:02]] |")); #expect(s.hasSuffix("^t00-12-34\n"))
    var mins = Samples.minutes; mins.nextActions = [.init(text: "A|B 比較", owner: nil, due: nil, t: "00:00:06")]
    #expect(doc(mins).render().contains("| A\\|B 比較 | — | — | [[#^t00-00-05\\|00:06]] |"))
}

@Test func transcriptOnlyOmitsMinutesSections() {
    let d = doc(nil, status: .transcriptOnly); let s = d.render()
    #expect(!s.contains("## 3行要約")); #expect(s.contains("> 議事録は未生成です。`autonote regenerate 20261024-1400-a1b2` で作り直せます。\n"))
    #expect(s.contains("status: transcript_only")); #expect(s.contains("\n# 2026-10-24 14:00 の会議\n"))
    #expect(d.preferredFileName == "2026-10-24_140000.md")
    #expect(doc(Samples.minutes, title: "改名後").title == "改名後"); #expect(doc(Samples.minutes).preferredFileName == "2026-10-24_1400_プロジェクト定例.md")
}

@Test func insertedFieldsFlattenNewlinesAndEmptySectionsSayNone() {
    var mins = Samples.minutes
    mins.title = "a\nb"; mins.summary = ["x\ny"]; mins.decisions = [Decision(text: "d\ne", t: "bad")]
    mins.agenda = [AgendaItem(title: "t\nu", body: "p\nq", t: "00:00:06")]
    mins.nextActions = []
    let s = doc(mins).render()
    #expect(s.contains("\n# a b\n")); #expect(s.contains("- x y\n")); #expect(s.contains("- d e\n"))
    #expect(s.contains("### 1. t u\np q [[#^t00-00-05|00:06]]\n")); #expect(s.contains("## Next Action\n- なし\n"))
}
