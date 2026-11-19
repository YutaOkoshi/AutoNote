import Foundation

/// The four parts of the live summary, top to bottom. Each one opens and closes on its own; the state is kept per
/// section in the app's defaults (`storageKey`) and shared by the recording pane and the post-stop card.
/// The old whole-card key `live_summary_card_collapsed` is no longer read.
public enum LiveSummarySection: String, CaseIterable, Sendable {
    case now, questions, todos, decisions

    public var title: String {
        switch self {
        case .now: "いまの話題"
        case .questions: "聞きたいこと"
        case .todos: "宿題"
        case .decisions: "決定事項"
        }
    }

    /// SF Symbol shown before the title.
    public var symbol: String {
        switch self {
        case .now: "bubble.left"
        case .questions: "questionmark.circle"
        case .todos: "checklist"
        case .decisions: "star"
        }
    }

    /// The top three are open; 決定事項 is closed (its count still shows).
    public var expandedByDefault: Bool { self != .decisions }

    public var storageKey: String { "live_summary_section_\(rawValue)_expanded" }

    /// The open / close button's accessibility label.
    public func toggleLabel(expanded: Bool) -> String { expanded ? "\(title)を閉じる" : "\(title)を開く" }
}

/// One row of 「聞きたいこと」.
public struct LiveQuestionRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var asked: Bool
    /// Marked by the live summary (not by hand).
    public var byModel: Bool
    /// 「聞けた」 / 「まだ」 (the check's accessibility value).
    public var stateLabel: String
    public var toggleLabel: String
    public var deleteLabel: String
    public var editLabel: String

    public init(_ q: LiveQuestion) {
        id = q.id
        text = q.text
        asked = q.asked
        byModel = q.asked && q.askedBy == .model
        stateLabel = q.asked ? "聞けた" : "まだ"
        toggleLabel = q.asked ? "「\(q.text)」を未にする" : "「\(q.text)」を聞けたにする"
        deleteLabel = "「\(q.text)」を削除"
        editLabel = "「\(q.text)」の文言を編集"
    }
}

/// One accent-coloured subheading of 宿題 (自分 / 相手 / その他) and its items.
public struct LiveTodoGroup: Equatable, Sendable {
    public var title: String
    public var items: [String]
    /// Each item's translation (index-aligned with `items`), the owner kept as it is; nil where there is none.
    public var translations: [String?]

    public init(title: String, items: [String], translations: [String?]? = nil) {
        self.title = title; self.items = items
        self.translations = translations ?? Array(repeating: nil, count: items.count)
    }
}

/// What the live summary pane (or the post-stop card) shows.
public struct LiveSummaryPaneContent: Equatable, Sendable {
    public var sections: [LiveSummarySection]
    /// nil when there is no topic (see `placeholder(.now)`).
    public var now: String?
    public var questions: [LiveQuestionRow]
    public var todoGroups: [LiveTodoGroup]
    public var decisions: [String]
    /// The translations under the topic and each decision (index-aligned); nil where there is none or while the
    /// 「訳文」 switch is off (spec 2026-11-19 表示).
    public var nowTranslation: String? = nil
    public var decisionTranslations: [String?] = []
    /// Questions can be added, renamed and removed (the recording pane and the draft); the post-stop card only toggles.
    public var editable: Bool
    public var canAddQuestion: Bool
    /// 「要約を休止中（Claude の利用制限）」 / 「要約を更新できません」; nil while active.
    public var status: String?
    /// 「n 秒前に更新」, only in the recording pane.
    public var updated: String?
    /// Whether a summary result exists (it decides 「（まだありません）」 versus 「（なし）」).
    public var hasResult: Bool

    /// The faint line under a section with nothing to list; nil when it has content.
    public func placeholder(_ section: LiveSummarySection) -> String? {
        let empty: Bool = switch section {
        case .now: now == nil
        case .questions: questions.isEmpty
        case .todos: todoGroups.isEmpty
        case .decisions: decisions.isEmpty
        }
        guard empty else { return nil }
        if section == .questions || !hasResult { return LiveSummaryPresentation.notYet }
        return LiveSummaryPresentation.emptyItem
    }

    /// Right of the title: 「聞けた数 / 全数」 for the questions, 「(件数)」 for the decisions once there is a result.
    public func badge(_ section: LiveSummarySection) -> String? {
        switch section {
        case .questions: questions.isEmpty ? nil : "\(questions.filter(\.asked).count) / \(questions.count)"
        case .decisions: hasResult ? "(\(decisions.count))" : nil
        case .now, .todos: nil
        }
    }
}

/// Side by side when the detail column is wide enough, otherwise the summary above the transcript.
public enum LiveSummaryArrangement: Equatable, Sendable {
    case sideBySide(paneWidth: Double)
    case stacked
}

public enum LiveSummaryLayout {
    public static let sideBySideMinWidth: Double = 720
    public static let paneFraction: Double = 0.45
    public static let paneMinWidth: Double = 320
    /// The stacked summary keeps the old card's cap.
    public static let stackedMaxHeight: Double = 220

    public static func paneWidth(total: Double) -> Double { max(paneMinWidth, (total * paneFraction).rounded()) }

    public static func arrangement(width: Double) -> LiveSummaryArrangement {
        width >= sideBySideMinWidth ? .sideBySide(paneWidth: paneWidth(total: width)) : .stacked
    }
}

/// What the recording screen shows next to the transcript.
public enum RecordingSummaryMode: Equatable, Sendable {
    /// The live summary pane, from the start of the recording.
    case sidePane
    /// Summaries off: only the questions, small, above the transcript (never sent to Claude).
    case questionsOnly
}

/// The copy and the assembly of the live summary pane, its post-stop card and the questions draft.
public enum LiveSummaryPresentation {
    public static let paneTitle = "ライブ要約"
    public static let transcriptTitle = "文字起こし"
    public static let emptyItem = "（なし）"
    public static let notYet = "（まだありません）"
    public static let pausedText = "要約を休止中（Claude の利用制限）"
    public static let failingText = "要約を更新できません"
    public static let mineTitle = "自分"
    public static let theirsTitle = "相手"
    public static let otherTitle = "その他"
    public static let addQuestionTitle = "聞きたいことを追加"
    public static let addQuestionPrompt = "聞きたいことを入力して Return"
    public static let questionLimitNote = "聞きたいことは \(LiveQuestionList.limit) 件までです"
    public static let draftTitle = "次の会議で聞きたいこと"
    public static let draftNote = "録音を始めると、その会議の「聞きたいこと」に移ります。"
    public static let deleteTitle = "削除"
    public static let editTitle = "文言を編集"

    /// The toolbar button that opens the draft while idle.
    public static func draftButton(count: Int) -> String { count == 0 ? "聞きたいこと" : "聞きたいこと (\(count))" }

    /// Whole seconds since `updatedAt`, never negative.
    public static func updatedText(updatedAt: Date, now: Date) -> String {
        "\(max(0, Int(now.timeIntervalSince(updatedAt)))) 秒前に更新"
    }

    /// The transcript pane header's right end.
    public static func transcriptStatus(_ state: RecorderState) -> String? {
        switch state {
        case .recording: "認識中"
        case .paused: "一時停止中"
        case .idle, .countdown, .grace: nil
        }
    }

    /// With summaries on, the pane shows from the start (it is where the questions are written). Off, only the
    /// questions — unless results already exist (turned off mid-recording).
    public static func recordingMode(liveSummaryEnabled: Bool, hasResult: Bool) -> RecordingSummaryMode {
        liveSummaryEnabled || hasResult ? .sidePane : .questionsOnly
    }

    /// The recording pane: all four sections, questions editable.
    /// `translation` is the live summary's (nil when hidden or none).
    public static func pane(state: LiveSummaryState?, status: LiveSummaryStatus, updated: String?,
                            questions: [LiveQuestion], translation: SummaryTranslationDocument? = nil) -> LiveSummaryPaneContent {
        content(sections: LiveSummarySection.allCases, state: state, questions: questions, editable: true,
                status: statusText(status), updated: updated, translation: translation)
    }

    /// The questions alone (summaries off while recording, or the draft before recording).
    public static func questionsOnly(_ questions: [LiveQuestion]) -> LiveSummaryPaneContent {
        content(sections: [.questions], state: nil, questions: questions, editable: true, status: nil, updated: nil)
    }

    /// The post-stop card (processing, minutes missing): nil with neither a summary nor questions. Questions only
    /// toggle; their section shows only when there are some.
    public static func stored(state: LiveSummaryState?, questions: [LiveQuestion],
                              translation: SummaryTranslationDocument? = nil) -> LiveSummaryPaneContent? {
        guard state != nil || !questions.isEmpty else { return nil }
        let sections = LiveSummarySection.allCases.filter { s in
            s == .questions ? !questions.isEmpty : state != nil
        }
        return content(sections: sections, state: state, questions: questions, editable: false, status: nil, updated: nil,
                       translation: translation)
    }

    private static func content(sections: [LiveSummarySection], state: LiveSummaryState?, questions: [LiveQuestion],
                                editable: Bool, status: String?, updated: String?,
                                translation: SummaryTranslationDocument? = nil) -> LiveSummaryPaneContent {
        let now = state.map(\.now).flatMap { $0.isEmpty ? nil : $0 }
        let decisions = state?.decisions ?? []
        var c = LiveSummaryPaneContent(sections: sections, now: now, questions: questions.map(LiveQuestionRow.init),
                                       todoGroups: todoGroups(state?.todos ?? [], translation: translation),
                                       decisions: decisions,
                                       editable: editable, canAddQuestion: editable && questions.count < LiveQuestionList.limit,
                                       status: status, updated: updated, hasResult: state != nil)
        c.nowTranslation = now.flatMap { translation?.translation(of: $0) }
        c.decisionTranslations = decisions.map { translation?.translation(of: $0) }
        return c
    }

    /// 自分 → 相手 → その他, each in the order given, empty ones left out; an owner reads `text — owner` (in the
    /// translation too).
    static func todoGroups(_ todos: [LiveSummaryTodo], translation: SummaryTranslationDocument? = nil) -> [LiveTodoGroup] {
        let order: [(LiveTodoSide, String)] = [(.me, mineTitle), (.other, theirsTitle), (.unknown, otherTitle)]
        func line(_ text: String, _ owner: String?) -> String { owner.map { "\(text) — \($0)" } ?? text }
        return order.compactMap { side, title in
            let group = todos.filter { $0.side == side }
            guard !group.isEmpty else { return nil }
            return LiveTodoGroup(title: title, items: group.map { line($0.text, $0.owner) },
                                 translations: group.map { t in translation?.translation(of: t.text).map { line($0, t.owner) } })
        }
    }

    private static func statusText(_ status: LiveSummaryStatus) -> String? {
        switch status {
        case .active: nil
        case .pausedForRateLimit: pausedText
        case .failing: failingText
        }
    }
}
