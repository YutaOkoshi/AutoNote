import AutoNoteCore
import Testing

@Suite struct LanguagePresentationTests {
    /// 「自動」は日本語と英語の 2 択（ほかの言語は出さない）と分かる文面にする。
    @Test func autoSaysItChoosesBetweenJapaneseAndEnglish() {
        #expect(LanguagePresentation.label(.auto) == "自動（日本語・英語）")
        #expect(LanguagePresentation.label(.ja) == "日本語")
        #expect(LanguagePresentation.label(.en) == "英語")
        for machine in [MachineKind.appleSilicon, .intel] {
            let note = LanguagePresentation.autoNote(machine: machine)
            #expect(note.contains("日本語か英語かを判定します（ほかの言語にはしません）。"))
            #expect(note.hasSuffix(appleLive))
            #expect(!note.contains("うまく起き"))   // 「起きる」は文字起こしの意味で読みにくい
            #expect(note.count <= 140, "設定の注記は短く（詳細はガイド）: \(note.count) 字")
        }
    }

    private let appleLive = "録音中のエンジンが Apple の音声認識（既定）のときは、録音中の表示・リアルタイム要約・録音中の翻訳は日本語の認識のままで、英語は停止後の文字起こしで出ます。"

    /// Apple シリコンは発言ごと（AutoLanguageSplitting.perBlock）、Intel は約 10 分ごと（perWindow）。
    @Test func theNoteSaysHowOftenTheFinalTranscriptionJudges() {
        #expect(LanguagePresentation.autoNote(machine: .appleSilicon).hasPrefix("自動では、停止後の文字起こしで発言ごとに"))
        #expect(LanguagePresentation.autoNote(machine: .intel).hasPrefix("自動では、停止後の文字起こしで約 10 分ごとに"))
    }

    /// 録音画面とメニューのピッカーのヘルプ: Apple のライブでの帰結と、英語だけの会議の対処。
    @Test func pickerHelpSaysWhatAppleLiveDoesAndWhatToDo() {
        #expect(LanguagePresentation.pickerHelp == "自動（日本語・英語）は、日本語と英語のどちらかを判定して文字起こしします。" + appleLive
            + "英語だけの会議なら「英語」を選んでください。")
    }
}
