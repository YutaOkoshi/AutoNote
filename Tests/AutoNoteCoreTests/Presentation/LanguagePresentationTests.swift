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
            #expect(note.hasPrefix("自動では、日本語と英語のどちらかを判定して文字起こしします（ほかの言語にはしません）。"))
            #expect(note.hasSuffix("ライブのエンジンが Apple の音声認識（既定）のときは、録音中の文字起こしは日本語として扱い、録音後の文字起こしで日本語と英語を判定します。"))
            #expect(!note.contains("うまく起き"))   // 「起きる」は文字起こしの意味で読みにくい
        }
    }

    /// 効く場面（交代で話す会議）と効かない場面（一文の中で混ざる言葉）を書く。
    @Test func appleSiliconNoteSaysWhereAutoWorksAndWhereItDoesNot() {
        let note = LanguagePresentation.autoNote(machine: .appleSilicon)
        #expect(note.contains("ある程度まとまった発言ごとに判定し直す"))
        #expect(note.contains("日本語と英語を交代で話す会議にも使えます"))
        #expect(note.contains("一文の中で混ざる言葉（日本語の中の英単語など）や短い一言は、前後の言語で起こします"))
        #expect(note.contains("判定が確かでない発言は、直前の言語のまま起こすことがあります"))
    }

    /// メニューバーと録音画面のピッカーのヘルプ: Apple のライブでは録音中は日本語のまま。
    @Test func pickerHelpSaysAppleLiveStaysJapanese() {
        #expect(LanguagePresentation.pickerHelp == "自動（日本語・英語）は、日本語と英語のどちらかを判定して文字起こしします。ライブのエンジンが Apple の音声認識（既定）のときは、録音中の文字起こしは日本語として扱い、録音後の文字起こしで日本語と英語を判定します。")
    }

    /// Intel は窓ごとに 1 回の判定だけ（AutoLanguageSplitting.perWindow）なので、交代で話す会議に効くとは書かない。
    @Test func intelNoteSaysTheFinalTranscriptionJudgesOncePerTenMinutes() {
        let note = LanguagePresentation.autoNote(machine: .intel)
        #expect(note.contains("確定版は約 10 分ごとに、その始めの部分で判定した言語で起こします"))
        #expect(note.contains("後から出てきた言語が正しく文字起こしされないことがあります"))
        #expect(!note.contains("交代で話す会議にも使えます"))
    }
}
