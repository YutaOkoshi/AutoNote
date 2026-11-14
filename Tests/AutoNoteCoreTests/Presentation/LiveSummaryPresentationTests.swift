import Foundation
import Testing
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct LiveSummaryPresentationTests {
    private func state(now: String = "ブログ記事の告知", decisions: [String] = [], todos: [LiveSummaryTodo] = []) -> LiveSummaryState {
        LiveSummaryState(now: now, decisions: decisions, todos: todos, consumedThrough: 85, updatedAt: Samples.start)
    }

    private let questions = [
        LiveQuestion(id: "a", text: "会場のキャパシティ", asked: true, askedBy: .model),
        LiveQuestion(id: "b", text: "入館証の締め切り", asked: true, askedBy: .user),
        LiveQuestion(id: "c", text: "当日の受付は誰がやるか"),
        LiveQuestion(id: "d", text: "録画の公開範囲", asked: false, askedBy: .user),
    ]

    @Test func updatedTextCountsSeconds() {
        let t = Samples.start
        #expect(LiveSummaryPresentation.updatedText(updatedAt: t, now: t + 42) == "42 秒前に更新")
        #expect(LiveSummaryPresentation.updatedText(updatedAt: t, now: t + 42.9) == "42 秒前に更新")
        #expect(LiveSummaryPresentation.updatedText(updatedAt: t, now: t - 3) == "0 秒前に更新")
    }

    // MARK: - Sections

    @Test func sectionsInOrderWithTitlesSymbolsAndDefaults() {
        #expect(LiveSummarySection.allCases == [.now, .questions, .todos, .decisions])
        #expect(LiveSummarySection.allCases.map(\.title) == ["いまの話題", "聞きたいこと", "宿題", "決定事項"])
        #expect(LiveSummarySection.allCases.map(\.expandedByDefault) == [true, true, true, false])
        #expect(LiveSummarySection.allCases.allSatisfy { !$0.symbol.isEmpty })
        #expect(LiveSummarySection.allCases.map(\.storageKey) == ["live_summary_section_now_expanded",
                                                                  "live_summary_section_questions_expanded",
                                                                  "live_summary_section_todos_expanded",
                                                                  "live_summary_section_decisions_expanded"])
        // The old whole-card key is not reused.
        #expect(!LiveSummarySection.allCases.map(\.storageKey).contains("live_summary_card_collapsed"))
        #expect(LiveSummarySection.questions.toggleLabel(expanded: true) == "聞きたいことを閉じる")
        #expect(LiveSummarySection.decisions.toggleLabel(expanded: false) == "決定事項を開く")
    }

    // MARK: - Recording pane

    /// Before the first result every summary section says 「（まだありません）」; the questions are there already.
    @Test func paneBeforeTheFirstResult() {
        let p = LiveSummaryPresentation.pane(state: nil, status: .active, updated: nil, questions: [])
        #expect(p.sections == [.now, .questions, .todos, .decisions])
        #expect(p.now == nil && p.todoGroups.isEmpty && p.decisions.isEmpty)
        #expect(p.placeholder(.now) == "（まだありません）")
        #expect(p.placeholder(.questions) == "（まだありません）")
        #expect(p.placeholder(.todos) == "（まだありません）")
        #expect(p.placeholder(.decisions) == "（まだありません）")
        #expect(p.badge(.questions) == nil && p.badge(.decisions) == nil)
        #expect(p.canAddQuestion && p.editable)
    }

    @Test func paneWithAResult() {
        let s = state(decisions: (1...11).map { "決定 \($0)" },
                      todos: [.init(text: "参加者リストを 21 日夜までに共有", owner: nil, side: .me),
                              .init(text: "36 階への案内 PDF を送る", owner: "佐藤", side: .other),
                              .init(text: "議事録の置き場を決める", owner: nil, side: .unknown),
                              .init(text: "会場を押さえる", owner: nil, side: .me)])
        let p = LiveSummaryPresentation.pane(state: s, status: .pausedForRateLimit, updated: "11 秒前に更新", questions: questions)
        #expect(p.now == "ブログ記事の告知" && p.placeholder(.now) == nil)
        #expect(p.todoGroups == [
            LiveTodoGroup(title: "自分", items: ["参加者リストを 21 日夜までに共有", "会場を押さえる"]),
            LiveTodoGroup(title: "相手", items: ["36 階への案内 PDF を送る — 佐藤"]),
            LiveTodoGroup(title: "その他", items: ["議事録の置き場を決める"])])
        #expect(p.placeholder(.todos) == nil)
        #expect(p.decisions.count == 11 && p.badge(.decisions) == "(11)")
        #expect(p.badge(.questions) == "2 / 4")
        #expect(p.questions.map(\.asked) == [true, true, false, false])
        #expect(p.status == "要約を休止中（Claude の利用制限）" && p.updated == "11 秒前に更新")
    }

    /// Empty groups are not shown; with none at all (or an empty topic) the section says 「（なし）」.
    @Test func emptyGroupsAndListsShowNone() {
        let s = state(now: "", todos: [.init(text: "相手の宿題", owner: nil, side: .other)])
        let p = LiveSummaryPresentation.pane(state: s, status: .active, updated: nil, questions: [])
        #expect(p.todoGroups == [LiveTodoGroup(title: "相手", items: ["相手の宿題"])])
        #expect(p.now == nil && p.placeholder(.now) == "（なし）")
        #expect(p.placeholder(.decisions) == "（なし）" && p.badge(.decisions) == "(0)")
        let none = LiveSummaryPresentation.pane(state: state(), status: .failing, updated: nil, questions: [])
        #expect(none.todoGroups.isEmpty && none.placeholder(.todos) == "（なし）")
        #expect(none.status == "要約を更新できません")
    }

    @Test func questionRowsCarryTheirLabels() {
        let p = LiveSummaryPresentation.pane(state: nil, status: .active, updated: nil, questions: questions)
        let asked = p.questions[0], open = p.questions[2]
        #expect(asked.id == "a" && asked.text == "会場のキャパシティ" && asked.asked)
        #expect(asked.stateLabel == "聞けた" && open.stateLabel == "まだ")
        #expect(asked.toggleLabel == "「会場のキャパシティ」を未にする")
        #expect(open.toggleLabel == "「当日の受付は誰がやるか」を聞けたにする")
        #expect(open.deleteLabel == "「当日の受付は誰がやるか」を削除")
        #expect(open.editLabel == "「当日の受付は誰がやるか」の文言を編集")
        #expect(asked.byModel && !p.questions[1].byModel)
    }

    @Test func fullListCannotAddMore() {
        let full = (0..<30).map { LiveQuestion(id: "q\($0)", text: "問い \($0)") }
        let p = LiveSummaryPresentation.pane(state: nil, status: .active, updated: nil, questions: full)
        #expect(!p.canAddQuestion)
        #expect(p.badge(.questions) == "0 / 30")
        #expect(LiveSummaryPresentation.questionLimitNote == "聞きたいことは 30 件までです")
    }

    // MARK: - Questions alone (summaries off, or before recording)

    @Test func questionsOnly() {
        let p = LiveSummaryPresentation.questionsOnly(questions)
        #expect(p.sections == [.questions] && p.editable && p.canAddQuestion)
        #expect(p.badge(.questions) == "2 / 4")
        #expect(p.status == nil && p.updated == nil)
        #expect(LiveSummaryPresentation.questionsOnly([]).placeholder(.questions) == "（まだありません）")
    }

    // MARK: - After the stop

    @Test func storedCardIsNilWithNothingToShow() {
        #expect(LiveSummaryPresentation.stored(state: nil, questions: []) == nil)
    }

    /// The same parts, read-only (the checks still toggle); questions only when there are some.
    @Test func storedCard() throws {
        let withBoth = try #require(LiveSummaryPresentation.stored(state: state(), questions: questions))
        #expect(withBoth.sections == [.now, .questions, .todos, .decisions])
        #expect(!withBoth.editable && !withBoth.canAddQuestion)
        #expect(withBoth.status == nil && withBoth.updated == nil)
        let noQuestions = try #require(LiveSummaryPresentation.stored(state: state(), questions: []))
        #expect(noQuestions.sections == [.now, .todos, .decisions])
        // A recording made with summaries off: only the questions.
        let onlyQuestions = try #require(LiveSummaryPresentation.stored(state: nil, questions: questions))
        #expect(onlyQuestions.sections == [.questions])
    }

    // MARK: - Layout and the transcript header

    @Test func layoutSideBySideFrom720() {
        #expect(LiveSummaryLayout.arrangement(width: 719) == .stacked)
        #expect(LiveSummaryLayout.arrangement(width: 720) == .sideBySide(paneWidth: 324))
        #expect(LiveSummaryLayout.arrangement(width: 1000) == .sideBySide(paneWidth: 450))
        #expect(LiveSummaryLayout.arrangement(width: 600) == .stacked)
        #expect(LiveSummaryLayout.paneWidth(total: 650) == 320)   // never under the minimum
        #expect(LiveSummaryLayout.stackedMaxHeight == 220)
    }

    @Test func recordingModeFollowsTheSetting() {
        #expect(LiveSummaryPresentation.recordingMode(liveSummaryEnabled: true, hasResult: false) == .sidePane)
        #expect(LiveSummaryPresentation.recordingMode(liveSummaryEnabled: false, hasResult: false) == .questionsOnly)
        // Turned off mid-recording after results: the pane stays with what it has.
        #expect(LiveSummaryPresentation.recordingMode(liveSummaryEnabled: false, hasResult: true) == .sidePane)
    }

    @Test func paneHeadersAndCopy() {
        #expect(LiveSummaryPresentation.paneTitle == "ライブ要約")
        #expect(LiveSummaryPresentation.transcriptTitle == "文字起こし")
        #expect(LiveSummaryPresentation.transcriptStatus(.recording) == "認識中")
        #expect(LiveSummaryPresentation.transcriptStatus(.paused) == "一時停止中")
        #expect(LiveSummaryPresentation.transcriptStatus(.idle) == nil)
        #expect(LiveSummaryPresentation.addQuestionTitle == "聞きたいことを追加")
        #expect(LiveSummaryPresentation.addQuestionPrompt == "聞きたいことを入力して Return")
        #expect(LiveSummaryPresentation.draftTitle == "次の会議で聞きたいこと")
        #expect(LiveSummaryPresentation.draftNote == "録音を始めると、その会議の「聞きたいこと」に移ります。")
        #expect(LiveSummaryPresentation.pausedText == "要約を休止中（Claude の利用制限）")
        #expect(LiveSummaryPresentation.failingText == "要約を更新できません")
        #expect(LiveSummaryPresentation.emptyItem == "（なし）")
        #expect(LiveSummaryPresentation.notYet == "（まだありません）")
        #expect(LiveSummaryPresentation.draftButton(count: 0) == "聞きたいこと")
        #expect(LiveSummaryPresentation.draftButton(count: 3) == "聞きたいこと (3)")
    }
}
