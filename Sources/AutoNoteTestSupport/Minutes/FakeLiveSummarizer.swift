import AutoNoteCore
import Foundation

/// Deterministic live summarizer: never fails, and each call appends one decision and one todo (taken on by 自分)
/// named after `consumedThrough` to the previous state, and marks the first question sent as asked.
public struct FakeLiveSummarizer: LiveSummarizer {
    public init() {}

    public func checkReady() async throws {}

    public func summarize(_ r: LiveSummaryRequest) async throws -> LiveSummaryOutput {
        let through = Int(r.consumedThrough)
        return LiveSummaryOutput(now: "発話 \(r.utterances.count) 件（\(through) 秒まで）",
                                 decisions: r.previous.decisions + ["決定（\(through) 秒まで）"],
                                 todos: r.previous.todos + [LiveSummaryTodo(text: "宿題（\(through) 秒まで）", owner: "架空の担当", side: .me)],
                                 askedQuestionIDs: r.questions.first.map { [$0.id] } ?? [])
    }
}
