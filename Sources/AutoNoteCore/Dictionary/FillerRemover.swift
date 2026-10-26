import Foundation

/// Removes standalone filler words (spec §6.5). Never removes partial matches inside a word.
public struct FillerRemover: Sendable {
    private let fillers: [String]
    private let fillerSet: Set<String>

    private static let terminators: Set<Character> = ["。", "．", ".", "!", "?", "！", "？"]
    private static let commas: Set<Character> = ["、", "，", ","]

    public init(fillers: [String]) {
        let folded = fillers.map(Self.fold).filter { !$0.isEmpty }
        self.fillers = folded
        self.fillerSet = Set(folded)
    }

    public func clean(_ text: String) -> String {
        let tokens = Self.tokenize(text)
        let content = tokens.filter { !$0.isSeparator }.map(\.text).joined()
        if content.isEmpty { return "" }
        if concatenatesFillers(Self.fold(content)) { return "" }

        var out: [Token] = []
        var removed = false
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            guard !t.isSeparator, fillerSet.contains(Self.fold(t.text)) else {
                out.append(t); i += 1; continue
            }
            removed = true
            let next: Token? = i + 1 < tokens.count ? tokens[i + 1] : nil
            if let sep = next, sep.text.contains(where: { Self.terminators.contains($0) }) {
                if let last = out.last, last.isSeparator { out.removeLast() }
                out.append(sep)
            }
            i += next == nil ? 1 : 2
        }
        if removed { out = Self.tidySeparators(out) }
        let result = out.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return result.contains(where: { !Self.isSeparator($0) }) ? result : ""
    }

    public func clean(_ utterances: [Utterance]) -> [Utterance] {
        utterances.compactMap { utterance in
            let text = clean(utterance.text)
            guard !text.isEmpty else { return nil }
            var copy = utterance
            copy.text = text
            return copy
        }
    }

    // MARK: - Internals

    private struct Token {
        var text: String
        var isSeparator: Bool
    }

    /// After a removal: no leading separators, no trailing comma-class run, and a comma-class run directly
    /// before a period-class run collapses into the period (「、。」 → 「。」).
    private static func tidySeparators(_ tokens: [Token]) -> [Token] {
        var merged: [Token] = []
        for t in tokens {
            if t.isSeparator, let last = merged.last, last.isSeparator {
                merged[merged.count - 1].text += t.text
            } else {
                merged.append(t)
            }
        }
        while let first = merged.first, first.isSeparator { merged.removeFirst() }
        if let last = merged.last, last.isSeparator, !last.text.contains(where: { terminators.contains($0) }) { merged.removeLast() }
        return merged.map { t in
            guard t.isSeparator, let firstStop = t.text.firstIndex(where: { terminators.contains($0) }) else { return t }
            let before = t.text[..<firstStop]
            guard !before.isEmpty, before.allSatisfy({ commas.contains($0) }) else { return t }
            return Token(text: String(t.text[firstStop...]), isSeparator: true)
        }
    }

    private static func isSeparator(_ c: Character) -> Bool {
        terminators.contains(c) || commas.contains(c) || c.isWhitespace
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for c in text {
            let sep = isSeparator(c)
            if let last = tokens.last, last.isSeparator == sep {
                tokens[tokens.count - 1].text.append(c)
            } else {
                tokens.append(Token(text: String(c), isSeparator: sep))
            }
        }
        return tokens
    }

    /// Lowercases ASCII letters only.
    private static func fold(_ s: String) -> String {
        String(s.map { c in
            if c.isASCII, c.isUppercase { return Character(c.lowercased()) }
            return c
        })
    }

    /// True when `s` can be written purely as a concatenation of fillers.
    private func concatenatesFillers(_ s: String) -> Bool {
        let chars = Array(s)
        var reachable = [Bool](repeating: false, count: chars.count + 1)
        reachable[0] = true
        for i in 0..<chars.count where reachable[i] {
            for f in fillers {
                let fc = Array(f)
                if i + fc.count <= chars.count, Array(chars[i..<(i + fc.count)]) == fc {
                    reachable[i + fc.count] = true
                }
            }
        }
        return reachable[chars.count]
    }
}
