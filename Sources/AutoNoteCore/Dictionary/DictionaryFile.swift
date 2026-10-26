import Foundation

public struct Replacement: Codable, Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) { self.from = from; self.to = to }
}

public struct DictionaryIssue: Equatable, Sendable {
    /// 1-based line number in the parsed Markdown.
    public var line: Int
    public var text: String
    public var reason: String

    public init(line: Int, text: String, reason: String) { self.line = line; self.text = text; self.reason = reason }
}

public struct DictionaryFile: Equatable, Sendable {
    public var terms: [String]
    public var replacements: [Replacement]
    public var fillers: [String]

    public init(terms: [String], replacements: [Replacement], fillers: [String]) {
        self.terms = terms; self.replacements = replacements; self.fillers = fillers
    }

    public static let defaultFillers = ["えー", "えーと", "あのー", "um", "uh"]
    public static let `default` = DictionaryFile(terms: [], replacements: [], fillers: defaultFillers)
    public static var defaultMarkdown: String { `default`.render() }

    private enum Section { case terms, replacements, fillers, other }

    public static func parse(_ markdown: String) -> (dictionary: DictionaryFile, issues: [DictionaryIssue]) {
        var terms: [String] = [], fillers: [String] = []
        var replacements: [Replacement] = []
        var issues: [DictionaryIssue] = []
        var seenFrom = Set<String>()
        var hasFillerSection = false
        var section: Section? = nil

        for (index, rawLine) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if line.hasPrefix("##") {
                    switch line.dropFirst(2).trimmingCharacters(in: .whitespaces) {
                    case "用語": section = .terms
                    case "置換": section = .replacements
                    case "フィラー": section = .fillers; hasFillerSection = true
                    default: section = .other
                    }
                } else {
                    section = .other
                }
                continue
            }
            guard let section, section != .other, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            switch section {
            case .terms: if !terms.contains(body) { terms.append(body) }
            case .fillers: if !fillers.contains(body) { fillers.append(body) }
            case .replacements:
                let brokenReason = "置換は「誤 => 正」の形で書く"
                guard let arrow = body.range(of: "=>") else {
                    issues.append(.init(line: lineNumber, text: body, reason: brokenReason)); continue
                }
                let from = body[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = body[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                if from.isEmpty || to.isEmpty {
                    issues.append(.init(line: lineNumber, text: body, reason: brokenReason))
                } else if !seenFrom.insert(from).inserted {
                    issues.append(.init(line: lineNumber, text: body, reason: "同じ「誤」が既にある（最初のものを使う）"))
                } else {
                    replacements.append(.init(from: from, to: to))
                }
            case .other: break
            }
        }
        let dictionary = DictionaryFile(terms: terms, replacements: replacements,
                                        fillers: hasFillerSection ? fillers : defaultFillers)
        return (dictionary, issues)
    }

    public func render() -> String {
        func block(_ heading: String, _ items: [String]) -> String {
            "## \(heading)\n" + items.map { "- \($0)\n" }.joined()
        }
        return [
            block("用語", terms),
            block("置換", replacements.map { "\($0.from) => \($0.to)" }),
            block("フィラー", fillers),
        ].joined(separator: "\n")
    }
}
