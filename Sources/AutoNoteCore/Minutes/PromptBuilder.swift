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
        let lines = utterances.map(Self.line)
        blocks.append(([Self.transcriptBegin] + lines + [Self.transcriptEnd]).joined(separator: "\n"))
        return blocks.joined(separator: "\n\n")
    }

    /// `[HH:MM:SS] 話者: 本文` with newlines flattened (shared with the live summary input).
    static func line(_ u: Utterance) -> String {
        "[\(u.start.hhmmss)] \(u.speaker.displayName): \(flatten(u.text))"
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

    // MARK: - Splitting long meetings

    /// Splits by rendered length: halve at the utterance before which the cumulative line length passes half,
    /// repeating on any part still over the threshold. `minimumParts` forces extra halvings (largest part first),
    /// capped at the number of utterances. Bookmarks go to the part whose start they follow (before the first part -> part 1).
    public func plan(_ input: SummaryInput, minimumParts: Int = 1) -> SummaryPlan {
        let all = input.transcript.utterances
        let single = SummaryPlan.single(prompt: build(input))
        if minimumParts <= 1, Self.estimateTokens(build(input)) <= Self.splitThresholdTokens { return single }
        guard all.count > 1 else { return single }

        // prefix[i] = rendered characters of lines 0..<i, each followed by one newline.
        var prefix = [0]
        prefix.reserveCapacity(all.count + 1)
        for u in all { prefix.append(prefix[prefix.count - 1] + Self.line(u).count + 1) }
        func weight(_ r: Range<Int>) -> Int { prefix[r.upperBound] - prefix[r.lowerBound] }

        func halves(_ r: Range<Int>) -> (Range<Int>, Range<Int>) {
            let half = Double(weight(r)) / 2
            var cut = r.lowerBound + 1
            while cut < r.upperBound - 1, Double(prefix[cut + 1] - prefix[r.lowerBound]) <= half { cut += 1 }
            // `cut` is the first utterance whose cumulative length exceeds half (so it starts the second part),
            // never the first utterance of the range: a part is never empty.
            return (r.lowerBound..<cut, cut..<r.upperBound)
        }

        func bookmarks(_ r: Range<Int>, isFirst: Bool, nextStart: TimelineTime?) -> [Bookmark] {
            let start = all[r.lowerBound].start
            return input.bookmarks.filter { b in
                (isFirst || b.at >= start) && (nextStart.map { b.at < $0 } ?? true)
            }
        }

        // Pessimistic part label (two digits each) so estimates never undershoot the final numbering.
        func estimate(_ r: Range<Int>) -> Int {
            var sub = input
            sub.bookmarks = bookmarks(r, isFirst: r.lowerBound == 0, nextStart: r.upperBound < all.count ? all[r.upperBound].start : nil)
            let base = build(sub, utterances: all[r.lowerBound..<r.lowerBound], part: (index: 99, count: 99)).count
            return Self.estimateTokens(String(repeating: " ", count: base + weight(r)))
        }

        var ranges = [0..<all.count]
        let target = min(max(minimumParts, 1), all.count)
        while ranges.count < target {
            guard let at = ranges.indices.filter({ ranges[$0].count > 1 }).max(by: { weight(ranges[$0]) < weight(ranges[$1]) }) else { break }
            let (a, b) = halves(ranges[at])
            ranges.replaceSubrange(at...at, with: [a, b])
        }
        var k = 0
        while k < ranges.count {
            if ranges[k].count > 1, estimate(ranges[k]) > Self.splitThresholdTokens {
                let (a, b) = halves(ranges[k])
                ranges.replaceSubrange(k...k, with: [a, b])
            } else {
                k += 1
            }
        }
        guard ranges.count > 1 else { return single }

        let n = ranges.count
        return .split(parts: ranges.enumerated().map { idx, r in
            var sub = input
            sub.bookmarks = bookmarks(r, isFirst: idx == 0, nextStart: idx + 1 < n ? all[ranges[idx + 1].lowerBound].start : nil)
            return build(sub, utterances: all[r], part: (index: idx + 1, count: n))
        })
    }

    /// Merge prompt: merge instructions, the per-part instructions (reference), then each partial as JSON data.
    public func mergePrompt(instructions: String, partials: [MinutesOutput]) -> String {
        let reference = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DefaultPrompt.instructions : instructions
        let encoder = AutoNoteJSON.encoder()
        var blocks = [DefaultPrompt.mergeInstructions, "## 各部の作成に使った指示文（参考）\n" + reference,
                      "----- ここから部分議事録（データ） -----"]
        for (i, p) in partials.enumerated() {
            let json = (try? encoder.encode(p)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            blocks.append("### 第 \(i + 1) 部\n" + json)
        }
        blocks.append("----- ここまで部分議事録 -----")
        return blocks.joined(separator: "\n\n")
    }
}

public enum SummaryPlan: Equatable, Sendable {
    case single(prompt: String)
    case split(parts: [String])
}
