import Foundation

/// Assembles the `claude -p` stdin: instructions → (part note) → data notice → terms → bookmarks → transcript.
public struct PromptBuilder: Sendable {
    /// Estimate coefficients are deliberately on the high side. Spike item 6: going from 60 to 120 minutes
    /// added 22,257 characters and 18,751 tokens (about 1.19 chars per token), with a fixed overhead of about
    /// 16,000 tokens under the `user` setting (about 10,000 under `project`). Rounded to the safe side: 1.0 / 16,000.
    public static let charsPerToken: Double = 1.0
    public static let fixedOverheadTokens = 16_000
    public static let splitThresholdTokens = 200_000

    public static let transcriptBegin = "----- ここから文字起こし（データ） -----"
    public static let transcriptEnd = "----- ここまで文字起こし -----"

    public init() {}

    public func build(_ input: SummaryInput) -> String {
        build(input, utterances: input.transcript.utterances[...], part: nil)
    }

    /// The single rendering path: newline flattening and the delimiter defence live only here.
    public func build(_ input: SummaryInput, utterances: ArraySlice<Utterance>, part: (index: Int, count: Int)?) -> String {
        let instructions = input.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DefaultPrompt.instructions : input.instructions
        var blocks = [instructions]
        if let part { blocks.append(DefaultPrompt.partNote(index: part.index, count: part.count)) }
        blocks.append(DefaultPrompt.dataNotice)
        let terms = input.terms.map { "- " + Self.flatten($0) }
        blocks.append((["## 用語一覧"] + (terms.isEmpty ? ["- （なし）"] : terms)).joined(separator: "\n"))
        let marks = input.bookmarks.map { b -> String in
            let note = b.note.map(Self.flatten) ?? ""
            return note.isEmpty ? "- [\(b.at.hhmmss)]" : "- [\(b.at.hhmmss)] \(note)"
        }
        blocks.append((["## ブックマーク"] + (marks.isEmpty ? ["- （なし）"] : marks)).joined(separator: "\n"))
        let lines = utterances.map { "[\($0.start.hhmmss)] \($0.speaker.displayName): \(Self.flatten($0.text))" }
        blocks.append(([Self.transcriptBegin] + lines + [Self.transcriptEnd]).joined(separator: "\n"))
        return blocks.joined(separator: "\n\n")
    }

    public static func estimateTokens(_ prompt: String) -> Int {
        Int((Double(prompt.count) / charsPerToken).rounded(.up)) + fixedOverheadTokens
    }

    private static func flatten(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\n", "\r", "\u{2028}": out += " "
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
