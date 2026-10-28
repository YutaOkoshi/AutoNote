import Foundation
import Testing
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct LiveSummaryPresentationTests {
    @Test func updatedTextCountsSeconds() {
        let t = Samples.start
        #expect(LiveSummaryPresentation.updatedText(updatedAt: t, now: t + 42) == "42 秒前に更新")
        #expect(LiveSummaryPresentation.updatedText(updatedAt: t, now: t + 42.9) == "42 秒前に更新")
        #expect(LiveSummaryPresentation.updatedText(updatedAt: t, now: t - 3) == "0 秒前に更新")
    }

    @Test func cardIsNilWithoutState() {
        #expect(LiveSummaryPresentation.card(state: nil, status: .failing, updated: nil) == nil)
        #expect(LiveSummaryPresentation.card(state: nil, status: .active, updated: "1 秒前に更新") == nil)
        #expect(LiveSummaryPresentation.card(state: nil, status: .pausedForRateLimit, updated: nil) == nil)
    }

    @Test func cardShowsOwnerAndStatus() {
        let s = LiveSummaryState(now: "", decisions: ["リリースは来週"],
                                 todos: [.init(text: "資料を送る", owner: "佐藤"), .init(text: "日程を決める", owner: nil)],
                                 consumedThrough: 85, updatedAt: Samples.start)
        #expect(LiveSummaryPresentation.card(state: s, status: .pausedForRateLimit, updated: "3 秒前に更新") ==
                LiveSummaryCardContent(now: "（なし）", decisions: ["リリースは来週"], todos: ["資料を送る — 佐藤", "日程を決める"],
                                       status: "要約を休止中（Claude の利用制限）", updated: "3 秒前に更新"))
        #expect(LiveSummaryPresentation.card(state: s, status: .failing, updated: nil)?.status == "要約を更新できません")
        #expect(LiveSummaryPresentation.card(state: s, status: .active, updated: nil)?.status == nil)
    }

    @Test func emptyListsShowNone() {
        let s = LiveSummaryState(now: "見積もりの確認", decisions: [], todos: [], consumedThrough: 10, updatedAt: Samples.start)
        #expect(LiveSummaryPresentation.card(state: s, status: .active, updated: nil) ==
                LiveSummaryCardContent(now: "見積もりの確認", decisions: ["（なし）"], todos: ["（なし）"], status: nil, updated: nil))
    }

    @Test func titlesAndCopy() {
        #expect(LiveSummaryPresentation.nowTitle == "いま")
        #expect(LiveSummaryPresentation.decisionsTitle == "決定事項")
        #expect(LiveSummaryPresentation.todosTitle == "宿題")
        #expect(LiveSummaryPresentation.emptyItem == "（なし）")
        #expect(LiveSummaryPresentation.pausedText == "要約を休止中（Claude の利用制限）")
        #expect(LiveSummaryPresentation.failingText == "要約を更新できません")
    }
}
