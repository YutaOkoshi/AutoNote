import Foundation

/// Drops "me" utterances that are speaker echo of the "other" track (spec §5.6).
public struct EchoDeduplicator: Sendable {
    public struct Configuration: Sendable {
        public var window = 3.0
        public var similarityThreshold = 0.8
        public var minimumLength = 4
        public var containmentMinimumLength = 6

        public init(window: Double = 3.0, similarityThreshold: Double = 0.8,
                    minimumLength: Int = 4, containmentMinimumLength: Int = 6) {
            self.window = window; self.similarityThreshold = similarityThreshold
            self.minimumLength = minimumLength; self.containmentMinimumLength = containmentMinimumLength
        }

        public static let standard = Configuration()
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .standard) { self.configuration = configuration }

    public func deduplicate(_ utterances: [Utterance]) -> [Utterance] {
        let others = utterances.filter { $0.speaker == .other }
            .sorted { $0.start < $1.start }
            .map { (start: $0.start.seconds, end: ($0.end ?? $0.start).seconds, text: Self.normalize($0.text)) }
        return utterances.filter { m in
            guard m.speaker == .me else { return true }
            let text = Self.normalize(m.text)
            guard text.count >= configuration.minimumLength else { return true }
            let lo = m.start.seconds - configuration.window
            let hi = (m.end ?? m.start).seconds + configuration.window
            let candidates = others.filter { $0.start <= hi && lo <= $0.end }
            guard !candidates.isEmpty else { return true }
            if candidates.contains(where: { Self.similarity(text, $0.text) >= configuration.similarityThreshold }) { return false }
            if text.count >= configuration.containmentMinimumLength,
               candidates.map(\.text).joined().contains(text) { return false }
            return true
        }
    }

    /// NFKC, lowercase, then drop whitespace and punctuation/symbol characters.
    public static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// `1 - editDistance / max(length)` over Characters; 0 when both are empty.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...max(y.count, 1) where !y.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(longest)
    }
}
