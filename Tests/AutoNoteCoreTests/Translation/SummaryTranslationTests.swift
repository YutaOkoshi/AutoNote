@testable import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

/// Translating the summaries (spec 2026-11-19): which texts, which direction, what is kept and the stored files.
@Suite struct SummaryTranslationTests {
    static let minutes = MinutesOutput(
        title: "テナント移行の定例",
        summary: ["週末に六割を移した。", "残りは今月末までに移す。"],
        decisions: [Decision(text: "移行は今月末までに終える", t: "00:01:00")],
        agenda: [AgendaItem(title: "進捗", body: "六割を移した", t: "00:00:10")],
        nextActions: [NextAction(text: "残りの手順書を送る", owner: "佐藤", due: "2026-11-30", t: "00:02:00")],
        suggestedTerms: ["テナント"],
        attendees: [Attendee(name: "佐藤", role: "PM")],
        keyPoints: [MinutesPoint(text: "移行済みは六割", t: "00:00:10")],
        insights: [MinutesPoint(text: "週末の作業が効いた", t: "00:00:20")],
        questions: [MinutesQuestion(question: "月末に間に合うか", askedBy: "鈴木", isResolved: true,
                                    answer: "間に合う見込み", t: "00:03:00")],
        deadlines: [Deadline(description: "移行の締め切り", date: "2026-11-30", owner: "佐藤", t: "00:04:00")],
        followUps: [MinutesPoint(text: "来週の定例で確認する", t: "00:05:00")],
        risks: [Risk(description: "週末の作業者が足りない", severity: .high, mitigation: "応援を頼む", t: "00:06:00")],
        architectureDiagram: "graph TD\n  A[Tenant] --> B[Cluster]")

    static let live = LiveSummaryState(
        now: "テナント移行の進捗", decisions: ["月末までに終える", "応援を頼む"],
        todos: [LiveSummaryTodo(text: "手順書を送る", owner: "佐藤", side: .me)], consumedThrough: 30, updatedAt: nil)

    // MARK: - What is translated

    @Test func theLiveSummaryTranslatesTheTopicDecisionsAndHomework() {
        #expect(SummaryTranslation.liveTexts(Self.live) == ["テナント移行の進捗", "月末までに終える", "応援を頼む", "手順書を送る"])
        #expect(SummaryTranslation.liveTexts(.empty).isEmpty)
    }

    @Test func theMinutesTranslateTheirTextsButNotNamesDatesTimesOrTheDiagram() {
        let texts = SummaryTranslation.minutesTexts(Self.minutes)
        #expect(texts == [
            "週末に六割を移した。", "残りは今月末までに移す。", "テナント移行の定例", "進捗", "六割を移した",
            "移行済みは六割", "移行は今月末までに終える", "残りの手順書を送る", "月末に間に合うか", "間に合う見込み",
            "移行の締め切り", "来週の定例で確認する", "週末の作業者が足りない", "応援を頼む", "週末の作業が効いた",
        ])
        for kept in ["佐藤", "鈴木", "PM", "2026-11-30", "00:01:00", "テナント", Self.minutes.architectureDiagram!] {
            #expect(!texts.contains(kept), "\(kept)")
        }
    }

    // MARK: - Direction

    @Test func theTargetFollowsTheSettingAndNeverTheSummarysOwnLanguage() {
        #expect(SummaryTranslation.targetLanguage(summary: .ja, setting: .auto) == .en)
        #expect(SummaryTranslation.targetLanguage(summary: .en, setting: .auto) == .ja)
        #expect(SummaryTranslation.targetLanguage(summary: .ja, setting: .en) == .en)
        #expect(SummaryTranslation.targetLanguage(summary: .ja, setting: .ja) == nil)
        #expect(SummaryTranslation.targetLanguage(summary: .en, setting: .en) == nil)
        // The summary's language is read from the summary itself.
        #expect(SummaryTranslation.targetLanguage(for: SummaryTranslation.minutesTexts(Self.minutes), setting: .auto) == .en)
        #expect(SummaryTranslation.targetLanguage(for: ["We agreed to finish by the end of the month."], setting: .auto) == .ja)
        #expect(SummaryTranslation.targetLanguage(for: [], setting: .auto) == nil)
    }

    @Test func textsAlreadyInTheTargetOrWithoutLettersAreLeftAlone() {
        let pending = SummaryTranslation.pending(["月末までに終える", "Kubernetes", "2026-11-30", "月末までに終える"],
                                                 target: .en, document: nil)
        #expect(pending == [SummaryTranslationItem(text: "月末までに終える", source: .ja, target: .en)])
    }

    /// Review L3: only the entries in the direction the current setting gives are used; none when that is the
    /// summary's own language.
    @Test func onlyTheCurrentDirectionsTranslationsAreUsed() {
        let texts = ["月末までに終える"]
        let doc = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date(),
                                             entries: [SummaryTranslatedText(sourceHash: TranslationKey.textHash(texts[0]),
                                                                             sourceLanguage: .ja, targetLanguage: .en,
                                                                             text: "Finish by month end")])
        #expect(SummaryTranslation.current(doc, texts: texts, setting: .auto)?.translation(of: texts[0]) == "Finish by month end")
        #expect(SummaryTranslation.current(doc, texts: texts, setting: .en)?.translation(of: texts[0]) == "Finish by month end")
        #expect(SummaryTranslation.current(doc, texts: texts, setting: .ja) == nil)
        #expect(SummaryTranslation.current(nil, texts: texts, setting: .auto) == nil)
    }

    // MARK: - Running

    private func translate(_ texts: [String], _ document: inout SummaryTranslationDocument,
                           _ fake: FakeTextCompleter) async throws {
        _ = try await SummaryTranslation.run(&document, texts: texts, target: .en,
                                             translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
    }

    @Test func onlyChangedItemsAreTranslatedAgainAndGoneOnesAreDropped() async throws {
        let fake = FakeTextCompleter()
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto,
                                                  updatedAt: Date(timeIntervalSince1970: 0))
        try await translate(SummaryTranslation.liveTexts(Self.live), &document, fake)
        #expect(fake.snapshot.prompts.count == 4)
        #expect(document.translation(of: "月末までに終える") == "EN: 月末までに終える")
        // The next update rewords one decision and drops the other.
        var next = Self.live
        next.decisions = ["月末までに必ず終える"]
        try await translate(SummaryTranslation.liveTexts(next), &document, fake)
        #expect(fake.snapshot.prompts.count == 5)
        #expect(document.translation(of: "月末までに必ず終える") == "EN: 月末までに必ず終える")
        #expect(document.translation(of: "テナント移行の進捗") == "EN: テナント移行の進捗")
        #expect(document.translation(of: "月末までに終える") == nil)
        #expect(document.entries.count == 3)
    }

    @Test func aSummaryPromptCarriesNoHistoryAndRoomForLongParagraphs() async throws {
        let fake = FakeTextCompleter()
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date())
        let long = String(repeating: "週末に六割を移しました。", count: 40)
        try await translate(["一つ目の決定", long], &document, fake)
        #expect(fake.snapshot.prompts.count == 2)
        #expect(!fake.snapshot.prompts[1].contains("一つ目の決定"))
        #expect(fake.snapshot.maxTokens[1] > PlamoPrompt.maxTokens(for: long))
    }

    // MARK: - Context (Lead 差し戻し 2: 短い項目は同じ要約の本文を文脈として渡す)

    private static let input = "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>"

    /// The PFML history pairs a prompt carries before its own input, as (source, translation).
    private func historyPairs(_ prompt: String) -> [(String, String)] {
        let parts = prompt.components(separatedBy: Self.input).dropFirst().dropLast()
        return parts.map { part in
            let body = part.components(separatedBy: "<|plamo:msg|>")
            return (body[1].components(separatedBy: "<|plamo:tag|>")[0], body[2])
        }
    }

    @Test func minutesItemsCarryTheSummaryAndTheTitleAsContextNotAsOutput() async throws {
        let fake = FakeTextCompleter()
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date())
        let texts = SummaryTranslation.minutesTexts(Self.minutes)
        // The context's texts go first, so the title already has the summary and the items have both.
        #expect(Array(texts.prefix(3)) == Self.minutes.summary + [Self.minutes.title])
        _ = try await SummaryTranslation.run(&document, texts: texts, context: SummaryTranslation.minutesContext(Self.minutes),
                                             target: .en, translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        let prompts = fake.snapshot.prompts
        #expect(historyPairs(prompts[0]).isEmpty)
        // The title: the summary's paragraphs, already translated.
        #expect(historyPairs(prompts[2]).map(\.0) == Self.minutes.summary)
        // A short item: the last summary paragraph and the title (nearest last), each with its translation.
        let decision = try #require(prompts.first { FakeTextCompleter.lastInput($0)?.text == "移行は今月末までに終える" })
        let pairs = historyPairs(decision)
        #expect(pairs.map(\.0) == ["週末に六割を移した。", "残りは今月末までに移す。", "テナント移行の定例"])
        #expect(pairs.last?.1 == "EN: テナント移行の定例")
        // The context is never part of the stored translation.
        #expect(document.translation(of: "移行は今月末までに終える") == "EN: 移行は今月末までに終える")
    }

    /// The recent utterances fill what the summary's own context leaves (oldest first, the summary's nearest last).
    @Test func recentUtterancesFillTheContextTheSummaryLacks() {
        let recent = (1...3).map { TranslationPair(source: "発話\($0)", sourceLanguage: .ja, translation: "U\($0)", targetLanguage: .en) }
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date())
        #expect(SummaryTranslation.history(for: "話題", context: ["話題"], document: document, recent: recent).map(\.source)
                == ["発話1", "発話2", "発話3"])
        document.entries = [SummaryTranslatedText(sourceHash: TranslationKey.textHash("決定"), sourceLanguage: .ja,
                                                  targetLanguage: .en, text: "Decision")]
        #expect(SummaryTranslation.history(for: "話題", context: ["決定", "話題"], document: document, recent: recent)
                .map(\.source) == ["発話2", "発話3", "決定"])
    }

    @Test func aChangedContextAloneTranslatesNothingAgain() async throws {
        let fake = FakeTextCompleter()
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date())
        let run: (MinutesOutput) async throws -> Void = { m in
            _ = try await SummaryTranslation.run(&document, texts: SummaryTranslation.minutesTexts(m),
                                                 context: SummaryTranslation.minutesContext(m), target: .en,
                                                 translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        }
        try await run(Self.minutes)
        let first = fake.snapshot.prompts.count
        let hash = TranslationKey.textHash("移行は今月末までに終える")
        var renamed = Self.minutes
        renamed.title = "移行の定例会"
        try await run(renamed)
        // Only the new title: the items whose context changed keep their translations (the hash is the text's own).
        #expect(fake.snapshot.prompts.count == first + 1)
        #expect(document.entries.contains { $0.sourceHash == hash })
    }

    @Test func liveItemsCarryTheTopicAndTheLatestItems() async throws {
        let fake = FakeTextCompleter()
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date())
        _ = try await SummaryTranslation.run(&document, texts: SummaryTranslation.liveTexts(Self.live),
                                             context: SummaryTranslation.liveContext(Self.live), target: .en,
                                             translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        let prompts = fake.snapshot.prompts
        // The topic first (nothing yet to lean on), then each item with the latest items before it and the topic last.
        #expect(historyPairs(prompts[0]).isEmpty)
        #expect(historyPairs(prompts[1]).map(\.0) == ["テナント移行の進捗"])
        #expect(historyPairs(prompts[3]).map(\.0) == ["月末までに終える", "応援を頼む", "テナント移行の進捗"])
        // A newer topic gets the latest items, and itself is never its own context.
        var next = Self.live
        next.now = "当番の割り当て"
        _ = try await SummaryTranslation.run(&document, texts: SummaryTranslation.liveTexts(next),
                                             context: SummaryTranslation.liveContext(next), target: .en,
                                             translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        #expect(fake.snapshot.prompts.count == 5)
        #expect(historyPairs(fake.snapshot.prompts[4]).map(\.0) == ["月末までに終える", "応援を頼む", "手順書を送る"])
    }

    @Test func aMultiLineTextIsTranslatedLineByLine() async throws {
        let fake = FakeTextCompleter()
        let text = try await UtteranceTranslator(completer: fake).translateSummary("一行目\n\n二行目", from: .ja, to: .en)
        #expect(text == "EN: 一行目\n\nEN: 二行目")
        #expect(fake.snapshot.prompts.count == 2)
    }

    /// Review M2: an empty output (nothing usable, or a prompt too long even alone) is a failure, not a translation:
    /// it is not stored, and the next run tries it again. An empty entry left by an older build counts as missing.
    @Test func anEmptyOutputIsNotStoredAndIsTriedAgainNextTime() async throws {
        let fake = FakeTextCompleter(phrases: ["空になる": ""])
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .auto, updatedAt: Date())
        try await translate(["空になる"], &document, fake)
        #expect(document.entries.isEmpty)
        try await translate(["空になる"], &document, fake)
        #expect(fake.snapshot.prompts.count == 2)
        #expect(document.translation(of: "空になる") == nil)
        document.entries = [SummaryTranslatedText(sourceHash: TranslationKey.textHash("空になる"), sourceLanguage: .ja,
                                                  targetLanguage: .en, text: "")]
        #expect(SummaryTranslation.pending(["空になる"], target: .en, document: document).count == 1)
    }

    // MARK: - Stored files

    @Test func bothFilesSitNextToTheTranscriptAndLeaveTheSummariesAlone() throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let id = MeetingID(rawValue: "20261119-1000-a1b2")
        let store = TranslationStore(paths: paths)
        try LiveSummaryStore(paths: paths).save(Self.live, for: id)
        let liveBefore = try Data(contentsOf: paths.liveSummaryFile(id))
        var document = SummaryTranslationDocument(model: "2b", modelRevision: "r", target: .en,
                                                  updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        document.entries = [SummaryTranslatedText(sourceHash: TranslationKey.textHash("応援を頼む"), sourceLanguage: .ja,
                                                  targetLanguage: .en, text: "Ask for help")]
        try store.saveSummary(document, .live, for: id)
        try store.saveSummary(document, .minutes, for: id)
        #expect(store.summaryTranslationFile(id, .live).lastPathComponent == "live-summary-translation.json")
        #expect(store.summaryTranslationFile(id, .minutes).lastPathComponent == "minutes-translation.json")
        #expect(store.summaryTranslationFile(id, .live).deletingLastPathComponent() == paths.transcriptsDirectory(id))
        #expect(store.loadSummary(id, .live) == document)
        #expect(store.loadSummary(id, .minutes)?.translation(of: "応援を頼む") == "Ask for help")
        #expect(try Data(contentsOf: paths.liveSummaryFile(id)) == liveBefore)
        // A broken file reads as none (it is rewritten on the next run).
        try Data("{".utf8).write(to: store.summaryTranslationFile(id, .minutes))
        #expect(store.loadSummary(id, .minutes) == nil)
    }
}
