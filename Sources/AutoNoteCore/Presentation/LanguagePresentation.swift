/// Labels and notes for the meeting language setting.
public enum LanguagePresentation {
    /// The picker label of each language.
    public static func label(_ language: Language) -> String {
        switch language {
        case .auto: "自動（日本語・英語）"
        case .ja: "日本語"
        case .en: "英語"
        }
    }

    /// What "auto" does on the live engines from Apple (the default live engines): they have no language detection and
    /// use Japanese (`LocaleMapping`); the final transcription (whisper) still judges Japanese or English.
    static let appleLiveNote = "ライブのエンジンが Apple の音声認識（既定）のときは、録音中の文字起こしは日本語として扱い、録音後の文字起こしで日本語と英語を判定します。"

    /// Help on the language pickers of the menu bar and the recording screen (no room for the full note there).
    public static let pickerHelp = "自動（日本語・英語）は、日本語と英語のどちらかを判定して文字起こしします。" + appleLiveNote

    /// Under the default-language picker in Settings. AutoNote handles only Japanese and English, so "auto" picks one of
    /// the two (whisper); how finely the final transcription judges follows `AutoLanguageSplitting.for(machine)`.
    public static func autoNote(machine: MachineKind) -> String {
        let head = "自動では、日本語と英語のどちらかを判定して文字起こしします（ほかの言語にはしません）。"
        switch AutoLanguageSplitting.for(machine) {
        case .perBlock:
            return head + "確定版は、ある程度まとまった発言ごとに判定し直すので、日本語と英語を交代で話す会議にも使えます。一文の中で混ざる言葉（日本語の中の英単語など）や短い一言は、前後の言語で起こします。判定が確かでない発言は、直前の言語のまま起こすことがあります。" + appleLiveNote
        case .perWindow:
            return head + "この Mac（Intel）では処理時間を抑えるため、確定版は約 10 分ごとに、その始めの部分で判定した言語で起こします。途中で言語が変わる会議では、後から出てきた言語が正しく文字起こしされないことがあります。" + appleLiveNote
        }
    }
}
