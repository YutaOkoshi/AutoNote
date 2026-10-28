import Foundation

/// One live summary call: the previous state and the window of confirmed utterances to send.
public struct LiveSummaryRequest: Equatable, Sendable {
    public var previous: LiveSummaryState
    /// The window to send, oldest first.
    public var utterances: [Utterance]
    /// End second of the newest utterance in the window.
    public var consumedThrough: Double

    public init(previous: LiveSummaryState, utterances: [Utterance], consumedThrough: Double) {
        self.previous = previous; self.utterances = utterances; self.consumedThrough = consumedThrough
    }
}

/// Cuts the live transcript into the input of one live summary call and renders its prompt.
public enum LiveSummaryInputBuilder {
    public static let contextSeconds: Double = 120
    public static let characterLimit = 8_000
    public static let omittedMarker = "[前略]"

    /// Confirmed, non-marker utterances with non-blank text, in their original order.
    public static func finalUtterances(_ utterances: [Utterance]) -> [Utterance] {
        utterances.filter { u in
            u.isFinal && !LiveFeed.isMarker(u) && !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Everything after `previous.consumedThrough` plus at least the last `contextSeconds`; nil when nothing is new.
    public static func request(previous: LiveSummaryState, confirmed: [Utterance]) -> LiveSummaryRequest? {
        let usable = finalUtterances(confirmed)
        let newer = usable.filter { endSeconds($0) > previous.consumedThrough }
        guard let last = newer.map(endSeconds).max() else { return nil }
        let from = min(previous.consumedThrough, last - contextSeconds)
        let window = usable.enumerated()
            .filter { endSeconds($0.element) > from }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        return LiveSummaryRequest(previous: previous, utterances: window, consumedThrough: last)
    }

    /// One `PromptBuilder.line` per utterance; over `characterLimit`, the oldest lines (or the head of a lone
    /// huge line) are dropped and `omittedMarker` leads the block.
    public static func transcriptBlock(_ utterances: [Utterance]) -> String {
        let lines = utterances.map(PromptBuilder.line)
        let all = lines.joined(separator: "\n")
        guard all.count > characterLimit else { return all }
        let head = omittedMarker + "\n"
        let budget = characterLimit - head.count
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            let cost = line.count + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budget else { break }
            kept.append(line); used += cost
        }
        guard !kept.isEmpty else { return head + String((lines.last ?? "").suffix(budget)) }
        return head + kept.reversed().joined(separator: "\n")
    }

    /// instructions → data notice → previous state (compact JSON) → utterances.
    public static func prompt(_ r: LiveSummaryRequest) -> String {
        let json = (try? AutoNoteJSON.compactEncoder().encode(r.previous.output)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return [DefaultPrompt.liveInstructions, DefaultPrompt.liveDataNotice,
                "## 前回の状態\n" + json, "## 発話\n" + transcriptBlock(r.utterances)].joined(separator: "\n\n")
    }

    private static func endSeconds(_ u: Utterance) -> Double { (u.end ?? u.start).seconds }
}
