import Testing
@testable import AutoNoteCore

@Suite struct RepetitionFilterTests {
    private func segs(_ texts: [String]) -> [WhisperSegment] {
        texts.enumerated().map { WhisperSegment(start: Double($0.offset), end: Double($0.offset + 1), text: $0.element) }
    }

    @Test func dropsHallucinationPhrase() {
        #expect(RepetitionFilter.clean(segs(["ご視聴ありがとうございました"])).isEmpty)
        #expect(RepetitionFilter.clean(segs(["Thank you for watching."])).isEmpty)
        #expect(RepetitionFilter.clean(segs(["ご視聴ありがとうございました、と彼は言った"])).count == 1)
    }

    @Test func dropsEmptyAndPunctuationOnly() {
        #expect(RepetitionFilter.clean(segs(["", " 。、 ", "…"])).isEmpty)
    }

    @Test func dropsConsecutiveDuplicate() {
        let out = RepetitionFilter.clean(segs(["了解です", "了解です。", "次へ"]))
        #expect(out.map(\.text) == ["了解です", "次へ"])
        #expect(out.map(\.start) == [0, 2])
    }

    @Test func keepsNonConsecutiveDuplicate() {
        #expect(RepetitionFilter.clean(segs(["はい", "次へ", "はい"])).map(\.text) == ["はい", "次へ", "はい"])
    }

    @Test func collapsesInnerRepetition() {
        #expect(RepetitionFilter.clean(segs(["そうですねそうですねそうですねそうですね"])).map(\.text) == ["そうですね"])
        #expect(RepetitionFilter.clean(segs(["えーとあああああですね"])).map(\.text) == ["えーとあですね"])
    }

    @Test func keepsShortRepeats() {
        #expect(RepetitionFilter.clean(segs(["はいはい"])).map(\.text) == ["はいはい"])
        #expect(RepetitionFilter.clean(segs(["はいはいはい"])).map(\.text) == ["はいはいはい"])
    }

    @Test func keepsNumbers() {
        #expect(RepetitionFilter.clean(segs(["売上は10000円です"])).map(\.text) == ["売上は10000円です"])
        #expect(RepetitionFilter.clean(segs(["100000人"])).map(\.text) == ["100000人"])
        #expect(RepetitionFilter.clean(segs(["１００００円"])).map(\.text) == ["１００００円"])
        #expect(RepetitionFilter.clean(segs(["0.0.0.0.0"])).map(\.text) == ["0.0.0.0.0"])
        #expect(RepetitionFilter.clean(segs(["0,000,000,000,000"])).map(\.text) == ["0,000,000,000,000"])
    }

    @Test func nonDigitUnitsStillCollapse() {
        #expect(RepetitionFilter.clean(segs(["そうそうそうそうそう"])).map(\.text) == ["そう"])
        #expect(RepetitionFilter.clean(segs(["1円1円1円1円"])).map(\.text) == ["1円"])
    }
}
