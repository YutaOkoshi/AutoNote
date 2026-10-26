import Foundation

public struct Replacer: Sendable {
    private let rules: [(from: [Unicode.Scalar], to: String)]

    /// Longest `from` wins at each position; earlier rules win ties. Empty `from` is ignored.
    public init(_ rules: [Replacement]) {
        let usable = rules.filter { !$0.from.isEmpty }.map { (from: Array($0.from.unicodeScalars), to: $0.to) }
        self.rules = usable.enumerated()
            .sorted { $0.element.from.count != $1.element.from.count ? $0.element.from.count > $1.element.from.count : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Single left-to-right pass; replaced text is never scanned again. Case-sensitive.
    public func apply(_ text: String) -> String {
        guard !rules.isEmpty else { return text }
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            if let rule = rules.first(where: { matches($0.from, in: chars, at: i) }) {
                out.append(contentsOf: rule.to.unicodeScalars)
                i += rule.from.count
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return String(out)
    }

    public func apply(_ utterances: [Utterance]) -> [Utterance] {
        utterances.map { var copy = $0; copy.text = apply($0.text); return copy }
    }

    private func matches(_ pattern: [Unicode.Scalar], in chars: [Unicode.Scalar], at start: Int) -> Bool {
        guard start + pattern.count <= chars.count else { return false }
        for k in 0..<pattern.count where chars[start + k] != pattern[k] { return false }
        return true
    }
}
