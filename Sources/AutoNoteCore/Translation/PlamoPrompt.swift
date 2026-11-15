import Foundation

/// One translated pair the next prompt carries as history (oldest first).
public struct TranslationPair: Equatable, Sendable {
    public var source: String
    public var sourceLanguage: TranslationLanguage
    public var translation: String
    public var targetLanguage: TranslationLanguage

    public init(source: String, sourceLanguage: TranslationLanguage, translation: String,
                targetLanguage: TranslationLanguage) {
        self.source = source
        self.sourceLanguage = sourceLanguage
        self.translation = translation
        self.targetLanguage = targetLanguage
    }
}

/// The PLaMo 3 Translate prompt (PFML3), built directly as the model card recommends (research note §1, the same
/// order as the GGUF's `chat_template.jinja`). The runtime adds `<|plamo:bos|>` itself, so it is not written here.
///
/// ```
/// <|plamo:tag|>dataset<|plamo:msg|>translation
/// (history) <|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>…<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>…
/// <|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>(text)<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:key|>form<|plamo:val|>polite<|plamo:msg|>
/// ```
public enum PlamoPrompt {
    static let tag = "<|plamo:tag|>"
    static let msg = "<|plamo:msg|>"
    static let key = "<|plamo:key|>"
    static let val = "<|plamo:val|>"

    /// The model stops by emitting one of these (spec 4).
    public static let stopStrings = ["<|plamo:tag|>", "<|plamo:bos|>"]

    /// How many earlier pairs each prompt carries (spec 4: the previous three).
    public static let historyLimit = 3

    /// The PFML3 text for translating `text` from `source` to `target`, with the last `historyLimit` pairs of
    /// `history`. Translations into Japanese ask for the polite form (です・ます).
    public static func build(text: String, source: TranslationLanguage, target: TranslationLanguage,
                             history: [TranslationPair] = []) -> String {
        var p = "\(tag)dataset\(msg)translation"
        for pair in history.suffix(historyLimit) {
            p += input(pair.sourceLanguage) + sanitized(pair.source)
            p += "\(tag)output\(key)lang\(val)\(pair.targetLanguage.rawValue)\(msg)" + sanitized(pair.translation)
        }
        p += input(source) + sanitized(text)
        p += "\(tag)output\(key)lang\(val)\(target.rawValue)"
        if target == .ja { p += "\(key)form\(val)polite" }
        return p + msg
    }

    /// The generation cap for one utterance (spec 4: a runaway guard, never the normal stop). Twice the source's
    /// characters plus room for short lines, inside 64...512 tokens: Japanese is about a token per character and
    /// English about one per four, so a faithful translation stays well under it.
    public static func maxTokens(for text: String) -> Int {
        min(512, max(64, text.count * 2 + 32))
    }

    /// The model's output as stored: surrounding whitespace removed, and anything after a stray special token
    /// (a runtime that did not stop on it) cut.
    public static func cleaned(_ output: String) -> String {
        var s = output
        if let r = s.range(of: "<|plamo:") { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The runtime parses special tokens in the prompt, so text must never contain one: `<|` becomes `<｜`
    /// (a full-width bar), which reads the same and tokenizes as plain text.
    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "<|", with: "<｜")
    }

    private static func input(_ language: TranslationLanguage) -> String {
        "\(tag)input\(key)lang\(val)\(language.rawValue)\(msg)"
    }
}
