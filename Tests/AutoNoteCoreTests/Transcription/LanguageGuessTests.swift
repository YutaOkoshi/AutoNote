import AutoNoteCore
import Testing

@Suite struct LanguageGuessTests {
    /// 「自動」は日本語と英語の確率の大きい方。ほかの言語（韓国語など）がいくら高くても、この 2 つのどちらかになる。
    @Test func picksTheMoreProbableOfJapaneseAndEnglish() {
        #expect(LanguageGuess(ja: 0.6, en: 0.3).language == .ja)
        #expect(LanguageGuess(ja: 0.2, en: 0.7).language == .en)
        #expect(LanguageGuess(ja: 0.04, en: 0.05).language == .en)   // 残りの 0.91 が韓国語でも en
    }

    @Test func aTieGoesToJapanese() {
        #expect(LanguageGuess(ja: 0.3, en: 0.3).language == .ja)
        #expect(LanguageGuess(ja: 0, en: 0).language == .ja)
    }

    @Test func japaneseShareIsBetweenTheTwo() {
        #expect(LanguageGuess(ja: 0.3, en: 0.1).japaneseShare == 0.75)
        #expect(LanguageGuess(ja: 0, en: 0).japaneseShare == 0.5)
    }
}
