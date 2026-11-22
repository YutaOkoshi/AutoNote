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
    /// use Japanese (`LocaleMapping`), so English shows only after the final transcription (whisper) judges ja/en.
    static let appleLiveNote = "録音中のエンジンが Apple の音声認識（既定）のときは、録音中の表示・リアルタイム要約・録音中の翻訳は日本語の認識のままで、英語は停止後の文字起こしで出ます。"

    /// Help on the language pickers of the recording screen and the menu bar (a menu item gets no tooltip: SwiftUI sets
    /// no AXHelp on a Picker inside a MenuBarExtra menu, checked 2026-11-22 with a probe app on macOS 26).
    public static let pickerHelp = "自動（日本語・英語）は、日本語と英語のどちらかを判定して文字起こしします。" + appleLiveNote
        + "英語だけの会議なら「英語」を選んでください。"

    /// Under the default-language picker in Settings: what auto does and the Apple live caveat; the details are in the
    /// guide (docs/guide/getting-started.md「言語の設定」). How finely the final transcription judges follows
    /// `AutoLanguageSplitting.for(machine)`.
    public static func autoNote(machine: MachineKind) -> String {
        let head: String
        switch AutoLanguageSplitting.for(machine) {
        case .perBlock:
            head = "自動では、停止後の文字起こしで発言ごとに日本語か英語かを判定します（ほかの言語にはしません）。"
        case .perWindow:
            head = "自動では、停止後の文字起こしで約 10 分ごとに日本語か英語かを判定します（ほかの言語にはしません）。"
        }
        return head + appleLiveNote
    }
}
