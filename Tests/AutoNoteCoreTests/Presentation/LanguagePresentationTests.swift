import AutoNoteCore
import Testing

@Suite struct LanguagePresentationTests {
    /// 「自動」は日本語と英語の 2 択（ほかの言語は出さない）と分かる文面にする。
    @Test func autoSaysItChoosesBetweenJapaneseAndEnglish() {
        #expect(LanguagePresentation.label(.auto) == "自動（日本語・英語）")
        #expect(LanguagePresentation.label(.ja) == "日本語")
        #expect(LanguagePresentation.label(.en) == "英語")
        #expect(LanguagePresentation.autoNote.contains("日本語と英語のどちらかを自動で判定"))
        #expect(LanguagePresentation.autoNote.contains("Apple の音声認識のエンジンでは、自動は日本語として扱います"))
    }
}
