import Foundation

public enum LocaleMapping {
    /// Apple's engines are language-bound, so `auto` falls back to Japanese (the primary use).
    public static func locale(for language: Language) -> Locale {
        switch language {
        case .ja, .auto: return Locale(identifier: "ja-JP")
        case .en: return Locale(identifier: "en-US")
        }
    }

    /// Compares language code and region, so `ja_JP` (Apple) matches `ja-JP`.
    public static func contains(_ list: [Locale], _ target: Locale) -> Bool {
        list.contains {
            $0.language.languageCode == target.language.languageCode && $0.region == target.region
        }
    }
}
