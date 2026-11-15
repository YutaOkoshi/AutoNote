import Foundation

/// Decides an utterance's language from its characters (spec 5): kana or kanji → Japanese, other letters →
/// English, no letters at all (digits, symbols, empty) → nothing to translate.
public enum TranslationLanguageDetector {
    /// The utterance's language, or nil when it has no letters.
    public static func language(of text: String) -> TranslationLanguage? {
        var hasLetter = false
        for scalar in text.unicodeScalars {
            if isJapanese(scalar) { return .ja }
            if !hasLetter, CharacterSet.letters.contains(scalar) { hasLetter = true }
        }
        return hasLetter ? .en : nil
    }

    /// The direction for `text` under `target`, or nil when it is not translated: no letters, or already in the
    /// fixed target language.
    public static func direction(of text: String, target: TranslationTarget)
        -> (source: TranslationLanguage, target: TranslationLanguage)? {
        guard let source = language(of: text) else { return nil }
        let to: TranslationLanguage = switch target {
        case .auto: source.opposite
        case .ja: .ja
        case .en: .en
        }
        return to == source ? nil : (source, to)
    }

    /// Hiragana, katakana (full and half width, phonetic extensions), CJK ideographs (unified, extension A,
    /// compatibility) and 々〆〇. The katakana block's punctuation (゠ and the middle dot ・) is not a letter.
    static func isJapanese(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30A0, 0x30FB: false
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: true
        case 0x3005, 0x3006, 0x3007: true
        default: false
        }
    }
}
