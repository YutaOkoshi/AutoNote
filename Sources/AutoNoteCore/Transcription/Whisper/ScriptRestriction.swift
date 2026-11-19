// whisper の語彙は多言語なので、言語を ja に固定しても greedy のライブではキリル文字・ハングル・デーヴァナーガリーの
// トークンが出ることがある（2026-11-19 の実データ。バッチの beam 5 では出ていない）。言語を固定したときは、その言語で
// 出てよい文字種のトークンだけを選べるように、デコード時に他のトークンの logit を落とす（WhisperContext の logits_filter_callback）。
// ja は日本語の会話に英単語が混ざるのでラテン文字も残す。auto は制限しない。

/// The scripts a decoder may emit for a language.
public enum ScriptRestriction: Sendable, Hashable {
    case unrestricted
    /// Kana, kanji, CJK punctuation, Latin, digits and symbols.
    case japanese
    /// Latin, digits and symbols.
    case english

    public init(language: Language) {
        switch language {
        case .ja: self = .japanese
        case .en: self = .english
        case .auto: self = .unrestricted
        }
    }

    /// Code points every restricted language keeps: Latin, digits, punctuation, symbols, emoji.
    private static let common: [ClosedRange<UInt32>] = [
        0x0000...0x036F,     // ASCII, Latin-1, Latin Extended-A/B, IPA, spacing modifiers, combining diacriticals
        0x1E00...0x1EFF,     // Latin Extended Additional
        0x2000...0x2BFF,     // general punctuation, currency, letterlike, number forms, arrows, math, box drawing, symbols
        0x2C60...0x2C7F,     // Latin Extended-C
        0xA720...0xA7FF,     // Latin Extended-D
        0xFB00...0xFB06,     // Latin ligatures
        0xFE00...0xFE0F,     // variation selectors
        0xFF00...0xFF5E,     // fullwidth ASCII
        0xFFE0...0xFFEE,     // fullwidth symbols
        0xFFF9...0xFFFD,     // specials
        0x1F000...0x1FAFF,   // emoji and pictographs
    ]

    private static let japaneseOnly: [ClosedRange<UInt32>] = [
        0x2E80...0x2FFF,     // CJK radicals, Kangxi radicals, ideographic description
        0x3000...0x30FF,     // CJK symbols and punctuation, hiragana, katakana
        0x3190...0x31FF,     // kanbun, CJK strokes, katakana phonetic extensions
        0x3200...0x9FFF,     // enclosed CJK, CJK compatibility, CJK unified ideographs (+ Extension A)
        0xF900...0xFAFF,     // CJK compatibility ideographs
        0xFE30...0xFE4F,     // CJK compatibility forms
        0xFF5F...0xFF9F,     // halfwidth CJK punctuation and katakana
        0x20000...0x3FFFF,   // CJK unified ideographs Extension B and later
    ]

    private static let japaneseRanges = (common + japaneseOnly).sorted { $0.lowerBound < $1.lowerBound }

    private var allowed: [ClosedRange<UInt32>]? {
        switch self {
        case .unrestricted: nil
        case .japanese: Self.japaneseRanges
        case .english: Self.common
        }
    }

    /// Whether a token with these raw bytes must not follow `pending` (the incomplete UTF-8 character the decoded
    /// text ends with, see `pendingPrefix`). A complete character outside the allowed scripts forbids the token; an
    /// incomplete one at the end forbids it when no character it can still become is allowed. Continuation bytes at
    /// the start with no `pending` belong to an unknown character and are skipped. Invalid bytes are ignored.
    public func forbids(_ bytes: [UInt8], after pending: [UInt8] = []) -> Bool {
        guard let allowed else { return false }
        let all = pending + bytes
        var i = 0
        if pending.isEmpty { while i < all.count, Self.isContinuation(all[i]) { i += 1 } }
        while i < all.count {
            guard let length = Self.sequenceLength(all[i]) else { i += 1; continue }
            var value = UInt32(all[i]) & (0xFF >> (length + 1))
            var have = 1
            while have < length, i + have < all.count, Self.isContinuation(all[i + have]) {
                value = value << 6 | UInt32(all[i + have] & 0x3F)
                have += 1
            }
            if have == length {
                if !Self.contains(allowed, value) { return true }
            } else if i + have == all.count {
                let free = UInt32(6 * (length - have))   // payload bits the missing bytes can still set
                let low = value << free
                if !Self.overlaps(allowed, low...(low | (1 << free - 1))) { return true }
            }
            i += have
        }
        return false
    }

    /// The trailing bytes of `bytes` that start a UTF-8 character but do not finish it (empty when the text ends on
    /// a character boundary).
    public static func pendingPrefix(_ bytes: [UInt8]) -> [UInt8] {
        var start = bytes.count
        while start > 0, bytes.count - start < 3, isContinuation(bytes[start - 1]) { start -= 1 }
        guard start > 0, let length = sequenceLength(bytes[start - 1]), length > bytes.count - start + 1 else { return [] }
        return Array(bytes[(start - 1)...])
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

    /// Bytes in the UTF-8 sequence this lead byte starts (nil for a continuation or invalid byte).
    private static func sequenceLength(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x00...0x7F: 1
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: nil
        }
    }

    private static func contains(_ ranges: [ClosedRange<UInt32>], _ value: UInt32) -> Bool {
        ranges.contains { $0.contains(value) }
    }

    private static func overlaps(_ ranges: [ClosedRange<UInt32>], _ span: ClosedRange<UInt32>) -> Bool {
        ranges.contains { $0.overlaps(span) }
    }
}

/// The tokens of one vocabulary a `ScriptRestriction` bans, worked out once per model. `vocabulary[id]` is the raw
/// bytes of text token `id`; ids at or past `vocabulary.count` (EOT, language, timestamps and other special tokens)
/// are never banned.
struct WhisperScriptFilter: Sendable {
    let restriction: ScriptRestriction
    /// Tokens banned at every step.
    let alwaysBanned: [Int32]
    private let vocabulary: [[UInt8]]
    /// Tokens that start with a continuation byte: the only ones that can finish a character split across tokens.
    private let continuations: [Int32]

    init(restriction: ScriptRestriction, vocabulary: [[UInt8]]) {
        self.restriction = restriction
        self.vocabulary = vocabulary
        var banned: [Int32] = []
        var continuations: [Int32] = []
        if restriction != .unrestricted {
            for (id, bytes) in vocabulary.enumerated() {
                if restriction.forbids(bytes) { banned.append(Int32(id)) }
                if let first = bytes.first, first & 0xC0 == 0x80 { continuations.append(Int32(id)) }
            }
        }
        alwaysBanned = banned
        self.continuations = continuations
    }

    /// Extra tokens to ban when the text decoded so far (`history`, token ids in order) ends inside a character:
    /// the continuations that would complete it as a character outside the allowed scripts.
    func banned(after history: [Int32]) -> [Int32] {
        guard restriction != .unrestricted else { return [] }
        var tail: [UInt8] = []
        for id in history.reversed() {
            guard id >= 0, Int(id) < vocabulary.count else { break }   // a special token ends the text run
            tail.insert(contentsOf: vocabulary[Int(id)], at: 0)
            if tail.count >= 3 { break }
        }
        let pending = ScriptRestriction.pendingPrefix(tail)
        guard !pending.isEmpty else { return [] }
        return continuations.filter { restriction.forbids(vocabulary[Int($0)], after: pending) }
    }
}
