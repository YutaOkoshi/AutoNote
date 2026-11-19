import Foundation

/// The one language a meeting's summaries are written in (spec 2026-11-19 要約の言語), for the live summary and the
/// minutes alike. Lead's call, open to change: the majority of the utterances, counted in characters, with the
/// translation's own per-line detection (kana or kanji → Japanese, other letters → English). Swap the rule here.
public enum SummaryLanguagePolicy {
    /// Japanese when the lines with kana or kanji hold more characters than the others, English otherwise; Japanese
    /// when nothing has letters (the app's own language).
    public static func decide(_ texts: [String]) -> TranslationLanguage {
        var ja = 0, en = 0
        for text in texts {
            switch TranslationLanguageDetector.language(of: text) {
            case .ja: ja += text.count
            case .en: en += text.count
            case nil: break
            }
        }
        if ja == 0 && en == 0 { return .ja }
        return ja > en ? .ja : .en
    }

    /// Over the confirmed utterances only (markers and partial lines do not count).
    public static func decide(utterances: [Utterance]) -> TranslationLanguage {
        decide(utterances.filter { $0.isFinal && !LiveFeed.isMarker($0) }.map(\.text))
    }
}
