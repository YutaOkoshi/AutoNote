import Foundation

public enum TranscriptMarkdown {
    /// One block anchor per utterance; repeated values get `-2`, `-3`, ...
    public static func anchors(for utterances: [Utterance]) -> [String] {
        var seen: [String: Int] = [:]
        return utterances.map { u in
            let base = u.start.anchor
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base)-\(n)"
        }
    }

    /// Candidates are utterances whose displayed second (`floor(start)`) is at or before `time`. Picks the last
    /// candidate that contains `time` (`start <= time <= end ?? start`), else the last candidate, else the first
    /// utterance; nil without utterances.
    public static func linkTarget(for time: TimelineTime, utterances: [Utterance], anchors: [String]) -> String? {
        guard !utterances.isEmpty, anchors.count == utterances.count else { return nil }
        let candidates = utterances.indices.filter { utterances[$0].start.seconds.rounded(.down) <= time.seconds }
        let containing = candidates.last { utterances[$0].start <= time && (utterances[$0].end ?? utterances[$0].start) >= time }
        return anchors[containing ?? candidates.last ?? 0]
    }

    public static func render(_ utterances: [Utterance], pauses: [PauseInterval]) -> String {
        let anchors = anchors(for: utterances)
        var remaining = pauses.sorted { $0.start < $1.start }[...]
        var paragraphs: [String] = []
        for (i, u) in utterances.enumerated() {
            while let p = remaining.first, p.start <= u.start {
                paragraphs.append(pauseParagraph(p)); remaining.removeFirst()
            }
            paragraphs.append("**[\(u.start.hhmmss)] \(u.speaker.displayName)**: \(flatten(u.text)) ^\(anchors[i])")
        }
        paragraphs += remaining.map(pauseParagraph)
        return paragraphs.isEmpty ? "" : paragraphs.joined(separator: "\n\n") + "\n"
    }

    /// Newlines inside an inserted sentence become one space.
    static func flatten(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func pauseParagraph(_ p: PauseInterval) -> String {
        "── 一時停止 \(p.start.hhmmss)〜\(p.end?.hhmmss ?? "") ──"
    }
}
