@testable import AutoNoteCore
import Foundation
import Testing

/// The summary's language (spec 要約の言語): decided per meeting from the utterances and named in every prompt.
@Suite struct SummaryLanguageTests {
    private func utt(_ s: Double, _ text: String, _ speaker: Speaker = .other) -> Utterance {
        Utterance(start: TimelineTime(seconds: s), end: TimelineTime(seconds: s + 2), speaker: speaker, text: text,
                  isFinal: true)
    }

    private func input(_ utterances: [Utterance], instructions: String = "指示X") -> SummaryInput {
        SummaryInput(instructions: instructions, terms: [], bookmarks: [],
                     transcript: Transcript(utterances: utterances, engine: "whisper", language: .auto), language: .auto)
    }

    private static let japanese = [
        "残りのテナントも今月末までに移せそうですか。", "週末に六割ほど移しました。", "では来週の定例で確認しましょう。",
    ]
    private static let english = [
        "We moved about sixty percent of the tenants over the weekend.", "It slipped twice already, right?",
        "Let's check again at next week's sync.",
    ]

    // MARK: - Deciding

    @Test func theMajorityByCharactersDecides() {
        #expect(SummaryLanguagePolicy.decide(Self.japanese) == .ja)
        #expect(SummaryLanguagePolicy.decide(Self.english) == .en)
        // One long English line outweighs two short Japanese ones.
        #expect(SummaryLanguagePolicy.decide(["はい。", "そうです。", Self.english[0]]) == .en)
        #expect(SummaryLanguagePolicy.decide(["OK", Self.japanese[0]]) == .ja)
    }

    @Test func nothingToCountFallsBackToJapanese() {
        #expect(SummaryLanguagePolicy.decide([]) == .ja)
        #expect(SummaryLanguagePolicy.decide(["123", "…"]) == .ja)
    }

    @Test func markersAndPartialLinesDoNotCount() {
        var partial = utt(9, Self.english[0])
        partial.isFinal = false
        let marker = Utterance(start: TimelineTime(seconds: 10), speaker: .unknown, text: LiveFeed.pauseMarkerText,
                               isFinal: true)
        #expect(SummaryLanguagePolicy.decide(utterances: [utt(0, "はい、そうしましょう。"), partial, marker]) == .ja)
    }

    // MARK: - Minutes prompt

    @Test func theMinutesPromptNamesTheLanguageRightAfterTheInstructions() throws {
        let ja = PromptBuilder().build(input(Self.japanese.enumerated().map { utt(Double($0.offset), $0.element) }))
        let en = PromptBuilder().build(input(Self.english.enumerated().map { utt(Double($0.offset), $0.element) }))
        #expect(ja.contains("指示X\n\n" + DefaultPrompt.languageLine(.ja) + "\n\n" + DefaultPrompt.dataNotice))
        #expect(en.contains("指示X\n\n" + DefaultPrompt.languageLine(.en) + "\n\n" + DefaultPrompt.dataNotice))
        #expect(DefaultPrompt.languageLine(.ja).contains("日本語で書く"))
        #expect(DefaultPrompt.languageLine(.en).contains("英語（English）で書く"))
    }

    /// A real English run (2026-11-19) ended in `error_max_turns`: an English title easily passes the schema's
    /// `maxLength`, the structured output is rejected and `--max-turns 1` leaves no turn to redo it. The English line
    /// names the schema's own limit (read from the schema, so the two cannot drift) and says spaces count.
    @Test func theEnglishLineNamesTheTitleLimitOfTheSchema() throws {
        let limit = try titleLimit(MinutesSchema.json(for: .en))
        let en = DefaultPrompt.languageLine(.en)
        #expect(en.contains("title は空白も含めて \(limit) 文字以内"))
        #expect(en.contains("超えると出力全体が受け付けられない"))
        // The Japanese line is as before (Japanese titles already fit).
        #expect(!DefaultPrompt.languageLine(.ja).contains("空白も含めて"))
    }

    private func schema(_ json: String) throws -> NSMutableDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8), options: .mutableContainers) as? NSMutableDictionary)
    }

    private func titleLimit(_ json: String) throws -> Int {
        let title = try #require((try schema(json)["properties"] as? [String: Any])?["title"] as? [String: Any])
        return try #require(title["maxLength"] as? Int)
    }

    /// Lead 差し戻し 2-5: the schema itself gives English titles room (60), Japanese keep 20; nothing else differs,
    /// the Japanese schema is the one in scripts/minutes-schema.json, and the limit fits a file name untruncated.
    @Test func theSchemasTitleLimitFollowsTheLanguage() throws {
        #expect(MinutesSchema.json(for: .ja) == MinutesSchema.json)
        #expect(try titleLimit(MinutesSchema.json(for: .ja)) == 20)
        #expect(try titleLimit(MinutesSchema.json(for: .en)) == 60)
        #expect(MinutesSchema.titleMaxLength(.ja) == 20 && MinutesSchema.titleMaxLength(.en) == 60)
        let ja = try schema(MinutesSchema.json(for: .ja)), en = try schema(MinutesSchema.json(for: .en))
        let jaProps = try #require(ja["properties"] as? NSMutableDictionary)
        let enProps = try #require(en["properties"] as? NSMutableDictionary)
        jaProps.removeObject(forKey: "title")
        enProps.removeObject(forKey: "title")
        #expect(ja == en)
        #expect(MeetingFileName.maxTitleLength >= MinutesSchema.titleMaxLength(.en))
    }

    @Test func anEditedPromptStillGetsTheLanguage() {
        let prompt = PromptBuilder().build(input(Self.english.enumerated().map { utt(Double($0.offset), $0.element) },
                                                 instructions: "日本語で、短く書いてください。"))
        #expect(prompt.contains(DefaultPrompt.languageLine(.en)))
    }

    @Test func everyPartAndTheMergeUseTheWholeMeetingsLanguage() {
        // A mostly English meeting whose last part is Japanese: every part is written in English.
        let utterances = (0..<6).map { utt(Double($0 * 10), Self.english[$0 % 3]) } + [utt(70, "最後だけ日本語です。")]
        let i = input(utterances)
        let part = PromptBuilder().build(i, utterances: i.transcript.utterances[6...], part: (index: 2, count: 2))
        #expect(part.contains(DefaultPrompt.languageLine(.en)))
        let merge = PromptBuilder().mergePrompt(instructions: "指示X", partials: [], language: .en)
        #expect(merge.contains(DefaultPrompt.languageLine(.en)))
    }

    @Test func theDefaultInstructionsNoLongerFixJapanese() {
        #expect(!DefaultPrompt.instructions.contains("日本語で書く"))
        #expect(DefaultPrompt.legacyInstructionsV2.contains("- 日本語で書く。"))
        #expect(PromptMigration.state(of: DefaultPrompt.legacyInstructionsV2) == .legacyDefault)
        #expect(PromptMigration.legacyDefaultSHA256s.contains(PromptMigration.sha256(DefaultPrompt.legacyInstructionsV2)))
        #expect(!PromptMigration.needsReview(DefaultPrompt.legacyInstructionsV2))
    }

    // MARK: - Live summary prompt

    @Test func theLiveRequestCarriesTheLanguageOfEverythingConfirmedSoFar() throws {
        let japanese = Self.japanese.enumerated().map { utt(Double($0.offset * 3), $0.element) }
        let r = try #require(LiveSummaryInputBuilder.request(previous: .empty, confirmed: japanese))
        #expect(r.language == .ja)
        let mixed = japanese + Self.english.enumerated().map { utt(Double(20 + $0.offset * 3), $0.element) }
            + [utt(40, Self.english[0]), utt(44, Self.english[0])]
        let later = try #require(LiveSummaryInputBuilder.request(previous: .empty, confirmed: mixed))
        #expect(later.language == .en)
    }

    @Test func theLivePromptNamesTheLanguageInsteadOfFollowingTheUtterances() throws {
        var r = try #require(LiveSummaryInputBuilder.request(previous: .empty, confirmed: [utt(0, Self.english[0])]))
        #expect(r.language == .en)
        let en = LiveSummaryInputBuilder.prompt(r)
        #expect(en.contains(DefaultPrompt.liveLanguageLine(.en)))
        #expect(!en.contains("発話と同じ言語で書く"))
        r.language = .ja
        #expect(LiveSummaryInputBuilder.prompt(r).contains(DefaultPrompt.liveLanguageLine(.ja)))
        #expect(DefaultPrompt.liveLanguageLine(.en).contains("英語（English）で書く"))
    }
}
