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

    /// Under the default-language picker in Settings. AutoNote handles only Japanese and English, so "auto" picks one of
    /// the two (whisper); Apple's recognizers have no detection and use Japanese.
    public static let autoNote = "自動では、日本語と英語のどちらかを自動で判定して文字起こしします（ほかの言語にはしません）。確定版は話の区切りごとに判定するので、日本語と英語が混ざる会議にも使えます。Apple の音声認識のエンジンでは、自動は日本語として扱います。"
}
