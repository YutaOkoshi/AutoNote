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
    let pos = try ["# プロジェクト定例", "## 議題", "## 要約", "## 決定事項", "## アクション", "## ブックマーク", "## 文字起こし"].map { try #require(s.range(of: "\n\($0)\n")).lowerBound }
    #expect(pos == pos.sorted()); #expect(s.contains("- [[#^t00-12-34|20:15]] 大事"))
    #expect(s.contains("| 中 | ドキュメント更新 | 自分 | 10/31 | [[#^t00-12-34\\|40:02]] |"))
    // A v1 document gets none of the v2 sections.
    for heading in ["## 出席者", "## 重要ポイント", "## 質問", "## 締め切り", "## フォローアップ", "## リスク", "## インサイト", "## 構成図", "## 3行要約", "## Next Action"] {
        #expect(!s.contains("\n\(heading)\n"), "\(heading)")
    }; #expect(s.hasSuffix("^t00-12-34\n"))
    var mins = Samples.minutes; mins.nextActions = [.init(text: "A|B 比較", owner: nil, due: nil, t: "00:00:06")]
    #expect(doc(mins).render().contains("| 中 | A\\|B 比較 | — | — | [[#^t00-00-05\\|00:06]] |"))
}

@Test func transcriptOnlyOmitsMinutesSections() {
    let d = doc(nil, status: .transcriptOnly); let s = d.render()
    #expect(!s.contains("## 要約")); #expect(s.contains("> 議事録は未生成です。`autonote regenerate 20261024-1400-a1b2` で作り直せます。\n"))
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
    #expect(s.contains("\n# a b\n")); #expect(s.contains("## 要約\nx y\n")); #expect(s.contains("- d e\n"))
    #expect(s.contains("### 1. t u\np q [[#^t00-00-05|00:06]]\n")); #expect(s.contains("## アクション\n- なし\n"))
}

@Test func v2DocumentHasEverySectionInOrder() throws {
    var mins = Samples.minutes
    mins.summary = ["一段落目。\n続き。", "二段落目。", "三段落目。"]
    mins.attendees = [Attendee(name: "佐藤", role: "PM"), Attendee(name: "相手")]
    mins.keyPoints = [MinutesPoint(text: "要点", t: "00:00:05")]
    mins.insights = [MinutesPoint(text: "気づき", t: "00:12:34")]
    mins.questions = [MinutesQuestion(question: "いつ出す？", askedBy: "相手", isResolved: true, answer: "来週", t: "00:12:34"),
                      MinutesQuestion(question: "予算は？", isResolved: false, t: "00:00:05")]
    mins.deadlines = [Deadline(description: "展示会", date: "11/20", t: "00:00:05"), Deadline(description: "締め", date: "11/1", owner: "自分", t: "00:12:34")]
    mins.followUps = [MinutesPoint(text: "次回確認", t: "00:12:34")]
    mins.risks = [Risk(description: "遅延", severity: .high, mitigation: "前倒し", t: "00:12:34"), Risk(description: "小さな懸念", severity: .low, t: "00:00:05")]
    mins.architectureDiagram = "```mermaid\ngraph LR\n  A[App] --> B[API]\n```"
    mins.nextActions[0].priority = .high
    let s = doc(mins).render()
    let order = ["# プロジェクト定例", "## 出席者", "## 議題", "## 要約", "## 重要ポイント", "## 決定事項", "## アクション", "## 質問", "## 締め切り",
                 "## フォローアップ", "## リスク", "## インサイト", "## 構成図", "## ブックマーク", "## 文字起こし"]
    let pos = try order.map { try #require(s.range(of: "\n\($0)\n")).lowerBound }
    #expect(pos == pos.sorted())
    for line in ["## 出席者\n佐藤（PM）、相手\n",
                 "## 要約\n一段落目。 続き。\n\n二段落目。\n\n三段落目。\n",
                 "- 要点 [[#^t00-00-05|00:05]]\n",
                 "| 優先度 | 内容 | 担当 | 期限 | 出典 |\n|---|---|---|---|---|\n| 高 | ドキュメント更新 |",
                 "- [x] いつ出す？ — 相手 [[#^t00-12-34|12:34]]\n  → 来週\n- [ ] 予算は？ [[#^t00-00-05|00:05]]\n",
                 "- 展示会 — 11/20 [[#^t00-00-05|00:05]]\n- 締め — 11/1（自分） [[#^t00-12-34|12:34]]\n",
                 "- 次回確認 [[#^t00-12-34|12:34]]\n",
                 "- 🔴 遅延 — 対策: 前倒し [[#^t00-12-34|12:34]]\n- 🔵 小さな懸念 [[#^t00-00-05|00:05]]\n",
                 "- 気づき [[#^t00-12-34|12:34]]\n",
                 "## 構成図\n```mermaid\ngraph LR\n  A[App] --> B[API]\n```\n"] {
        #expect(s.contains(line), "\(line)")
    }
}
