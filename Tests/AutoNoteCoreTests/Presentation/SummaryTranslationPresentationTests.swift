@testable import AutoNoteCore
import Foundation
import Testing

/// The summaries' translations on screen (spec 2026-11-19 表示): under each item's original, only with a translation
/// of that very text, nothing while the 「訳文」 switch is off.
@Suite struct SummaryTranslationPresentationTests {
    private func document(_ pairs: [(String, String)]) -> SummaryTranslationDocument {
        SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date(timeIntervalSince1970: 0),
                                   entries: pairs.map {
                                       SummaryTranslatedText(sourceHash: TranslationKey.textHash($0.0), sourceLanguage: .ja,
                                                             targetLanguage: .en, text: $0.1)
                                   })
    }

    @Test func theLivePaneCarriesATranslationPerItem() {
        let state = LiveSummaryState(
            now: "移行の進捗", decisions: ["月末までに終える", "応援を頼む"],
            todos: [LiveSummaryTodo(text: "手順書を送る", owner: "佐藤", side: .me),
                    LiveSummaryTodo(text: "日程を決める", owner: nil, side: .other)],
            consumedThrough: 10, updatedAt: nil)
        let doc = document([("移行の進捗", "Migration progress"), ("月末までに終える", "Finish by month end"),
                            ("手順書を送る", "Send the runbook")])
        let c = LiveSummaryPresentation.pane(state: state, status: .active, updated: nil, questions: [], translation: doc)
        #expect(c.nowTranslation == "Migration progress")
        #expect(c.decisionTranslations == ["Finish by month end", nil])
        #expect(c.todoGroups.map(\.translations) == [["Send the runbook — 佐藤"], [nil]])
        // Without a translation (or hidden) the pane is exactly as before.
        let plain = LiveSummaryPresentation.pane(state: state, status: .active, updated: nil, questions: [])
        #expect(plain.nowTranslation == nil && plain.decisionTranslations == [nil, nil])
        #expect(plain.todoGroups.map(\.translations) == [[nil], [nil]])
        let stored = LiveSummaryPresentation.stored(state: state, questions: [], translation: doc)
        #expect(stored?.decisionTranslations.first == "Finish by month end")
    }

    @Test func theMinutesRowsCarryTheirTranslations() throws {
        let m = SummaryTranslationTests.minutes
        let doc = document([("移行は今月末までに終える", "Finish the move this month"), ("間に合う見込み", "Likely on time"),
                            ("応援を頼む", "Ask for help"), ("テナント移行の定例", "Tenant migration sync"),
                            ("六割を移した", "Moved 60%")])
        let sections = MinutesPresentation.sections(m, translation: doc)
        func row(_ kind: MinutesSectionKind) throws -> MinutesRow {
            try #require(sections.first { $0.kind == kind }?.rows.first)
        }
        #expect(try row(.decisions).textTranslation == "Finish the move this month")
        #expect(try row(.questions).detailTranslation == "→ Likely on time")
        #expect(try row(.risks).detailTranslation == "対策: Ask for help")
        #expect(try row(.agenda).detailTranslation == "Moved 60%")
        #expect(try row(.attendees).textTranslation == nil)
        #expect(try row(.actions).secondary == "担当 佐藤・期限 2026-11-30")
        #expect(MinutesPresentation.titleTranslation(m, translation: doc) == "Tenant migration sync")
        // No document: the rows are the same as before.
        #expect(MinutesPresentation.sections(m) == MinutesPresentation.sections(m, translation: nil))
        #expect(MinutesPresentation.sections(m).allSatisfy { $0.rows.allSatisfy { $0.textTranslation == nil } })
    }

    @Test func theSwitchShowsWhenASummaryHasATranslation() {
        #expect(!TranslationPresentation.hasSummaryTranslation(nil))
        #expect(!TranslationPresentation.hasSummaryTranslation(document([("空", "")])))
        #expect(TranslationPresentation.hasSummaryTranslation(document([("決定", "Decision")])))
        // Hidden: nothing is handed to the views.
        #expect(TranslationPresentation.summaryTranslation(document([("決定", "Decision")]), shown: false) == nil)
        #expect(TranslationPresentation.summaryTranslation(document([("決定", "Decision")]), shown: true) != nil)
    }
}
