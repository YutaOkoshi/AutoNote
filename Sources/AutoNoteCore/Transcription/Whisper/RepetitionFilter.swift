/// Removes whisper's typical hallucinations and repetitions (要件書 §6.4).
enum RepetitionFilter {
    static let hallucinations: [String] = [
        "ご視聴ありがとうございました",
        "ご清聴ありがとうございました",
        "チャンネル登録よろしくお願いします",
        "Thank you for watching.",
    ]

    private static let normalizedHallucinations = Set(hallucinations.map(normalize))

    /// (1) drops segments that are empty without whitespace/punctuation, (2) drops segments that are a
    /// hallucination phrase, (3) drops a segment equal (normalized) to the previously kept one, and
    /// (4) collapses a 1–15 character run repeated 4+ times in a row to a single copy.
    static func clean(_ s: [WhisperSegment]) -> [WhisperSegment] {
        var kept: [WhisperSegment] = []
        var lastKey: String?
        for var segment in s {
            segment.text = collapseRepeats(segment.text)
            let key = normalize(segment.text)
            if key.isEmpty || normalizedHallucinations.contains(key) || key == lastKey { continue }
            kept.append(segment)
            lastKey = key
        }
        return kept
    }

    /// Lowercased text without whitespace, punctuation and symbols.
    static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { scalar in
            !(scalar.properties.isWhitespace || scalar.properties.generalCategory.isPunctuationOrSymbol)
        }))
    }

    static func collapseRepeats(_ text: String, maxUnit: Int = 15, minCount: Int = 4) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var i = 0
        outer: while i < chars.count {
            for unit in 1...maxUnit where i + unit * minCount <= chars.count {
                let pattern = chars[i..<i + unit]
                var count = 1
                while i + (count + 1) * unit <= chars.count, chars[(i + count * unit)..<(i + (count + 1) * unit)] == pattern {
                    count += 1
                }
                if count >= minCount {
                    out.append(contentsOf: pattern)
                    i += count * unit
                    continue outer
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }
}

private extension Unicode.GeneralCategory {
    var isPunctuationOrSymbol: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            true
        default:
            false
        }
    }
}
