import Foundation

/// What the live summary card shows: the three sections, the faint status line and the age line.
public struct LiveSummaryCardContent: Equatable, Sendable {
    public var now: String
    public var decisions: [String]
    public var todos: [String]
    /// 「要約を休止中（Claude の利用制限）」 / 「要約を更新できません」; nil while active.
    public var status: String?
    /// 「n 秒前に更新」, only on the recording card.
    public var updated: String?

    public init(now: String, decisions: [String], todos: [String], status: String?, updated: String?) {
        self.now = now
        self.decisions = decisions
        self.todos = todos
        self.status = status
        self.updated = updated
    }
}

/// The copy of the live summary card (plan 09). No card until the first result; the status line only inside one.
public enum LiveSummaryPresentation {
    public static let nowTitle = "いま"
    public static let decisionsTitle = "決定事項"
    public static let todosTitle = "宿題"
    public static let emptyItem = "（なし）"
    public static let pausedText = "要約を休止中（Claude の利用制限）"
    public static let failingText = "要約を更新できません"

    /// Whole seconds since `updatedAt`, never negative.
    public static func updatedText(updatedAt: Date, now: Date) -> String {
        "\(max(0, Int(now.timeIntervalSince(updatedAt)))) 秒前に更新"
    }

    /// nil until the first result. An empty `now` or list shows 「（なし）」; a todo with an owner is `text — owner`.
    public static func card(state: LiveSummaryState?, status: LiveSummaryStatus, updated: String?) -> LiveSummaryCardContent? {
        guard let state else { return nil }
        let todos = state.todos.map { t in t.owner.map { "\(t.text) — \($0)" } ?? t.text }
        let statusText: String? = switch status {
        case .active: nil
        case .pausedForRateLimit: pausedText
        case .failing: failingText
        }
        return LiveSummaryCardContent(now: state.now.isEmpty ? emptyItem : state.now,
                                      decisions: state.decisions.isEmpty ? [emptyItem] : state.decisions,
                                      todos: todos.isEmpty ? [emptyItem] : todos,
                                      status: statusText, updated: updated)
    }
}
