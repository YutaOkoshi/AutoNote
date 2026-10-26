import Testing
import Foundation
@testable import AutoNoteCore

@Suite struct PromptSplitTests {
    private func utts(_ n: Int, chars: Int = 1_000) -> [Utterance] {
        (0..<n).map { i in
            Utterance(start: TimelineTime(seconds: Double(i) * 10), speaker: i % 2 == 0 ? .me : .other,
                      text: String(repeating: "あ", count: chars), isFinal: true)
        }
    }

    private func input(_ u: [Utterance], bookmarks: [Bookmark] = [], terms: [String] = ["用語A"]) -> SummaryInput {
        SummaryInput(instructions: "指示X", terms: terms, bookmarks: bookmarks,
                     transcript: Transcript(utterances: u, engine: "whisper", language: .ja), language: .ja)
    }

    private func parts(_ plan: SummaryPlan) -> [String] {
        if case .split(let p) = plan { return p }
        return []
    }

    private func transcriptLines(_ prompt: String) -> [String] {
        let lines = prompt.components(separatedBy: "\n")
        guard let b = lines.firstIndex(of: PromptBuilder.transcriptBegin),
              let e = lines.lastIndex(of: PromptBuilder.transcriptEnd) else { return [] }
        return Array(lines[(b + 1)..<e])
    }

    @Test func underThresholdIsSingle() {
        let i = input(utts(10))
        #expect(PromptBuilder().plan(i) == .single(prompt: PromptBuilder().build(i)))
    }

    @Test func overThresholdSplitsInTwo() {
        let ps = parts(PromptBuilder().plan(input(utts(190))))
        #expect(ps.count == 2)
        for p in ps { #expect(PromptBuilder.estimateTokens(p) <= PromptBuilder.splitThresholdTokens) }
        #expect(ps[0].contains(DefaultPrompt.partNote(index: 1, count: 2)))
        #expect(ps[1].contains(DefaultPrompt.partNote(index: 2, count: 2)))
        #expect(!ps[0].contains(DefaultPrompt.partNote(index: 2, count: 2)))
    }

    @Test func veryLongSplitsRecursively() {
        let ps = parts(PromptBuilder().plan(input(utts(600))))
        #expect(ps.count == 4)
        for (k, p) in ps.enumerated() {
            #expect(PromptBuilder.estimateTokens(p) <= PromptBuilder.splitThresholdTokens)
            #expect(p.contains(DefaultPrompt.partNote(index: k + 1, count: 4)))
        }
    }

    @Test func partsCoverEveryUtteranceOnceInOrder() {
        let u = utts(190)
        let i = input(u)
        let all = transcriptLines(PromptBuilder().build(i))
        let joined = parts(PromptBuilder().plan(i)).flatMap(transcriptLines)
        #expect(all.count == 190)
        #expect(joined == all)
    }

    @Test func bookmarksGoOnlyToTheirPart() {
        let marks = [Bookmark(at: TimelineTime(seconds: 600), note: "前半印"),
                     Bookmark(at: TimelineTime(seconds: 1_880), note: "後半印")]
        let ps = parts(PromptBuilder().plan(input(utts(190), bookmarks: marks)))
        #expect(ps.count == 2)
        #expect(ps[0].contains("- [00:10:00] 前半印") && !ps[0].contains("後半印"))
        #expect(ps[1].contains("- [00:31:20] 後半印") && !ps[1].contains("前半印"))
    }

    @Test func bookmarksOutsideTheTranscriptGoToFirstAndLastPart() {
        var u = utts(4)
        for k in u.indices { u[k].start = TimelineTime(seconds: 100 + Double(k) * 10) }
        let marks = [Bookmark(at: TimelineTime(seconds: 5), note: "冒頭前"), Bookmark(at: TimelineTime(seconds: 9_999), note: "末尾後")]
        let ps = parts(PromptBuilder().plan(input(u, bookmarks: marks), minimumParts: 2))
        #expect(ps.count == 2)
        #expect(ps[0].contains("冒頭前") && !ps[0].contains("末尾後"))
        #expect(ps[1].contains("末尾後") && !ps[1].contains("冒頭前"))
    }

    @Test func termsGoToEveryPart() {
        let ps = parts(PromptBuilder().plan(input(utts(190), terms: ["固有語Q"])))
        #expect(ps.count == 2)
        for p in ps { #expect(p.contains("- 固有語Q")) }
    }

    @Test func minimumPartsForcesSplit() {
        let i = input(utts(10))
        let ps = parts(PromptBuilder().plan(i, minimumParts: 2))
        #expect(ps.count == 2)
        #expect(ps.flatMap(transcriptLines) == transcriptLines(PromptBuilder().build(i)))
    }

    @Test func minimumPartsAboveUtteranceCountUsesUtteranceCount() {
        let ps = parts(PromptBuilder().plan(input(utts(3)), minimumParts: 8))
        #expect(ps.count == 3)
        for p in ps { #expect(transcriptLines(p).count == 1) }
    }

    @Test func singleUtteranceCannotBeSplit() {
        let i = input(utts(1))
        #expect(PromptBuilder().plan(i, minimumParts: 3) == .single(prompt: PromptBuilder().build(i)))
    }

    @Test func hugeFirstUtteranceBecomesItsOwnPartAndNoPartIsEmpty() {
        var u = utts(4, chars: 10)
        u[0].text = String(repeating: "あ", count: 5_000)
        let ps = parts(PromptBuilder().plan(input(u), minimumParts: 2))
        #expect(ps.count == 2)
        #expect(transcriptLines(ps[0]).count == 1)
        #expect(transcriptLines(ps[1]).count == 3)
    }

    @Test func hugeMiddleUtteranceSplitsBeforeIt() {
        var u = utts(5, chars: 10)
        u[3].text = String(repeating: "あ", count: 5_000)
        let ps = parts(PromptBuilder().plan(input(u), minimumParts: 2))
        #expect(ps.count == 2)
        #expect(ps.allSatisfy { !transcriptLines($0).isEmpty })
        #expect(ps.flatMap(transcriptLines).count == 5)
    }

    @Test func planningSixHundredLongUtterancesIsFast() {
        let i = input(utts(600))
        let start = Date()
        _ = PromptBuilder().plan(i)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test func partNoteAndMergeInstructionsUseBriefTexts() {
        let note = DefaultPrompt.partNote(index: 1, count: 2)
        #expect(note.contains("2 部に分けたうちの第 1 部"))
        #expect(!note.contains("{n}") && !note.contains("{k}"))
        #expect(DefaultPrompt.mergeInstructions.hasPrefix("あなたは、一つの会議を時間順に分けて作った複数の部分議事録を、一つの議事録に統合します。"))
    }

    @Test func mergePromptContainsPartialsAsDataInOrder() throws {
        func out(_ title: String) -> MinutesOutput {
            MinutesOutput(title: title, summary: ["a", "b", "c"], decisions: [], agenda: [], nextActions: [], suggestedTerms: [])
        }
        let prompt = PromptBuilder().mergePrompt(instructions: "元の指示X", partials: [out("前半の会議"), out("後半の会議")])
        let needles = [DefaultPrompt.mergeInstructions, "## 各部の作成に使った指示文（参考）", "元の指示X",
                       "----- ここから部分議事録（データ） -----", "### 第 1 部", "\"title\" : \"前半の会議\"",
                       "### 第 2 部", "\"title\" : \"後半の会議\"", "----- ここまで部分議事録 -----"]
        var last = prompt.startIndex
        for n in needles {
            let r = try #require(prompt.range(of: n, range: last..<prompt.endIndex))
            last = r.upperBound
        }
        #expect(prompt.contains("\"suggested_terms\""))
    }
}
