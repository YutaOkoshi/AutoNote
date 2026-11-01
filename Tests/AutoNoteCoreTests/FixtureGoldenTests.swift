import Foundation
import Testing
import AutoNoteCore
import AutoNoteTestSupport

@Test func fixtureRendersToGolden() async throws {
    let out = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: out) }
    #expect(try await FixtureRenderer.render(into: out).count == 4)
    let differing = try FixtureRenderer.compare(out, expected: FixtureLibrary.defaultDirectory.appending(path: "expected"))
    #expect(differing == [], "golden differs: \(differing)")
}

@Test func goldenHasKeyLines() throws {   // golden が誤りごと作り直されるのを防ぐ
    let dir = FixtureLibrary.defaultDirectory.appending(path: "expected")
    let m1 = try String(contentsOf: dir.appending(path: "2026/2026-10-24_1400_ルミナ茶発売準備会議.md"), encoding: .utf8)
    for line in ["title: ルミナ茶発売準備会議", "end: \"14:05\"", "duration_min: 5", "- 発売日は来週の金曜 [[#^t00-03-50|03:50]]",
                 "- 価格は一本百八十円 [[#^t00-00-40|00:42]]", "| 販促物A\\|B 案の納期を回答する | — | 来週水曜 | [[#^t00-03-00\\|03:00]] |",
                 "- [[#^t00-00-40|00:41]] 価格の話", "- [[#^t00-03-50|03:51]]", "── 一時停止 00:02:30〜00:02:50 ──",
                 "**[00:00:12] 相手**: まず発売日ですが、来週の金曜を考えています。 ^t00-00-12", "**[00:00:20] 自分**: ルミナ茶の在庫は十分にありますか。 ^t00-00-20",
                 "**[00:00:40] 自分**: はい。 ^t00-00-40-2", "**[00:02:55] 相手**: 店頭の販促物はこちらで用意します。 ^t00-02-55"] { #expect(m1.contains(line + "\n"), "\(line)") }
    #expect(m1.contains("## 要約\nルミナ茶の発売日を来週金曜に確定した。\n\n価格は"))
    #expect(m1.contains("| 中 | 価格の社内承認を取る | 自分 | — | [[#^t00-01-00\\|01:00]] |\n"))
    for heading in ["## 出席者", "## 質問", "## リスク", "## 構成図", "## 3行要約", "## Next Action"] { #expect(!m1.contains("\n\(heading)\n"), "\(heading)") }
    #expect(m1.components(separatedBy: "**: ").count - 1 == 12)   // 15 発話から回り込み 2 とフィラーだけ 1 を除く
    let m2 = try String(contentsOf: dir.appending(path: "2026/2026-10-25_093015.md"), encoding: .utf8)
    for line in [#"title: "2026-10-25 09:30 の会議""#, "status: transcript_only", "device: \"import\"", "**[00:00:03] 不明**: 取り込んだ録音の確認です。 ^t00-00-03",
                 "**[00:00:30] 不明**: this part is in English. ^t00-00-30"] { #expect(m2.contains(line + "\n"), "\(line)") }
    // Schema v2: every section, in the spec order.
    let m3 = try String(contentsOf: dir.appending(path: "2026/2026-10-26_1000_ルミナ茶EC受注連携.md"), encoding: .utf8)
    let order = ["## 出席者", "## 議題", "## 要約", "## 重要ポイント", "## 決定事項", "## アクション", "## 質問", "## 締め切り",
                 "## フォローアップ", "## リスク", "## インサイト", "## 構成図", "## ブックマーク", "## 文字起こし"]
    let pos = try order.map { try #require(m3.range(of: "\n\($0)\n")).lowerBound }
    #expect(pos == pos.sorted())
    for line in ["相手（ほしぞら食品）、自分", "| 高 | 出荷システムの仕様書を送る | 相手 | 来週月曜 | [[#^t00-02-30\\|02:30]] |",
                 "- [x] 出荷システムの仕様書はいつ届くか — 自分 [[#^t00-02-10|02:10]]", "  → 来週月曜までに届く",
                 "- 結合テストの完了 — 12月10日（自分） [[#^t00-01-30|01:30]]",
                 "- 🔴 セール初日に注文が集中して受注APIが詰まる — 対策: 受注をキューに積んで順に処理する [[#^t00-03-05|03:05]]",
                 "```mermaid", "  EC[EC site] --> API[Order API]"] { #expect(m3.contains(line + "\n"), "\(line)") }
    #expect(try String(contentsOf: dir.appending(path: "_index.md"), encoding: .utf8).contains(
        "| 2026-10-26 | 10:00 | ルミナ茶EC受注連携 | 5 分 | ルミナ茶のEC受注を倉庫システムへ自動でつなぐ構成を相談した。"))
    #expect(try String(contentsOf: dir.appending(path: "_index.md"), encoding: .utf8).contains(
        "| 2026-10-25 | 09:30 | 2026-10-25 09:30 の会議 | 2 分 | （議事録未生成） | [[2026/2026-10-25_093015]] |\n| 2026-10-24 | 14:00 | ルミナ茶発売準備会議 | 5 分 | ルミナ茶の発売日を来週金曜に確定した。 | [[2026/2026-10-24_1400_ルミナ茶発売準備会議]] |\n"))
}
