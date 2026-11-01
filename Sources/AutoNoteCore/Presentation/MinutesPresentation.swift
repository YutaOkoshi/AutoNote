import Foundation

/// The 「要約」 tab's sections, top to bottom (spec F2 §3.4).
public enum MinutesSectionKind: String, CaseIterable, Sendable {
    case attendees, agenda, summary, keyPoints, decisions, insights, questions, deadlines, followUps, risks, diagram, actions
}

/// Colour kinds the view maps to its own colours (no SwiftUI here).
public enum MinutesTone: String, Equatable, Sendable {
    case red, orange, blue, green, yellow, secondary
}

public struct MinutesBadge: Equatable, Sendable {
    public var text: String
    public var tone: MinutesTone
    public init(text: String, tone: MinutesTone) { self.text = text; self.tone = tone }
}

/// One row of a section. Which fields are set depends on the section.
public struct MinutesRow: Equatable, Identifiable, Sendable {
    public var id: String
    /// The main line (an agenda item's title, a question, a risk...).
    public var text: String
    /// A smaller second line: a role, the asker, 「担当 … ・期限 …」, a deadline's date and owner.
    public var secondary: String?
    /// Red for a deadline's date; nil for the usual secondary colour.
    public var secondaryTone: MinutesTone?
    /// Shown under the row: an agenda item's body (opened on tap), `→ 回答`, `対策: …`.
    public var detail: String?
    public var badges: [MinutesBadge]
    /// The row's icon (SF Symbols) and its tone, e.g. the green check of a decision.
    public var symbol: String?
    public var symbolTone: MinutesTone?
    /// Where the row's time jumps to in the transcript, and its `MM:SS` text.
    public var time: TimelineTime?
    public var timeText: String?
    /// Actions only: what the priority filter looks at.
    public var priority: MinutesLevel?

    public init(id: String, text: String, secondary: String? = nil, secondaryTone: MinutesTone? = nil, detail: String? = nil,
                badges: [MinutesBadge] = [], symbol: String? = nil, symbolTone: MinutesTone? = nil,
                time: TimelineTime? = nil, priority: MinutesLevel? = nil) {
        self.id = id; self.text = text; self.secondary = secondary; self.secondaryTone = secondaryTone; self.detail = detail
        self.badges = badges; self.symbol = symbol; self.symbolTone = symbolTone
        self.time = time; self.timeText = time.map(MinutesPresentation.timeText); self.priority = priority
    }
}

public struct MinutesSection: Equatable, Identifiable, Sendable {
    public var kind: MinutesSectionKind
    public var title: String
    /// The heading's SF Symbol.
    public var symbol: String
    public var rows: [MinutesRow]
    /// The diagram section only: the Mermaid source.
    public var diagram: String?

    public var id: String { kind.rawValue }

    public init(kind: MinutesSectionKind, title: String, symbol: String, rows: [MinutesRow], diagram: String? = nil) {
        self.kind = kind; self.title = title; self.symbol = symbol; self.rows = rows; self.diagram = diagram
    }
}

/// The actions' priority filter: すべて / 高 / 中 / 低.
public enum MinutesActionFilter: String, CaseIterable, Identifiable, Sendable {
    case all, high, medium, low

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "すべて"
        case .high: MinutesPresentation.levelText(.high)
        case .medium: MinutesPresentation.levelText(.medium)
        case .low: MinutesPresentation.levelText(.low)
        }
    }

    var level: MinutesLevel? {
        switch self {
        case .all: nil
        case .high: .high
        case .medium: .medium
        case .low: .low
        }
    }
}

/// What the 「要約」 tab shows, as pure data: the section order, empty sections left out, badge copy and colour kinds,
/// the action filter, the `MM:SS` times, and the SF Symbols. The view only draws it.
public enum MinutesPresentation {
    public static func title(_ kind: MinutesSectionKind) -> String {
        switch kind {
        case .attendees: "出席者"
        case .agenda: "議題"
        case .summary: "要約"
        case .keyPoints: "重要ポイント"
        case .decisions: "決定事項"
        case .insights: "インサイト"
        case .questions: "質問"
        case .deadlines: "締め切り"
        case .followUps: "フォローアップ"
        case .risks: "リスク"
        case .diagram: "構成図"
        case .actions: "アクション"
        }
    }

    public static func symbol(_ kind: MinutesSectionKind) -> String {
        switch kind {
        case .attendees: "person.2"
        case .agenda: "list.number"
        case .summary: "doc.text"
        case .keyPoints: "list.bullet"
        case .decisions: "checkmark.seal"
        case .insights: "lightbulb"
        case .questions: "questionmark.bubble"
        case .deadlines: "calendar.badge.exclamationmark"
        case .followUps: "arrow.turn.down.right"
        case .risks: "exclamationmark.triangle"
        case .diagram: "square.stack.3d.up"
        case .actions: "checklist"
        }
    }

    public static let resolvedText = "解決済み"
    public static let unresolvedText = "未解決"
    public static let previewLabel = "プレビュー"
    public static let emptyFilterText = "この優先度のアクションはありません"

    public static func levelText(_ level: MinutesLevel) -> String {
        switch level {
        case .high: "高"
        case .medium: "中"
        case .low: "低"
        }
    }

    /// 高 = red, 中 = orange, 低 = blue (both the priority badge and the risk colour).
    public static func levelTone(_ level: MinutesLevel) -> MinutesTone {
        switch level {
        case .high: .red
        case .medium: .orange
        case .low: .blue
        }
    }

    /// The Vault's risk marker: 🔴 / 🟠 / 🔵.
    public static func severityEmoji(_ level: MinutesLevel) -> String {
        switch level {
        case .high: "🔴"
        case .medium: "🟠"
        case .low: "🔵"
        }
    }

    public static func resolvedBadge(_ isResolved: Bool) -> MinutesBadge {
        isResolved ? MinutesBadge(text: resolvedText, tone: .green) : MinutesBadge(text: unresolvedText, tone: .orange)
    }

    /// `MM:SS` (`H:MM:SS` from one hour on), as the Vault links show it.
    public static func timeText(_ time: TimelineTime) -> String { time.mmss }

    /// 「4 件」 next to the actions heading.
    public static func countText(_ count: Int) -> String { "\(count) 件" }

    /// The Mermaid source without surrounding blank lines or a stray ``` fence; nil when there is nothing to draw.
    public static func diagramSource(_ source: String?) -> String? {
        guard let source else { return nil }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The sections in display order, each without blank items; a section with nothing left is not shown.
    public static func sections(_ m: MinutesOutput) -> [MinutesSection] {
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func time(_ t: String) -> TimelineTime? { TimelineTime(hhmmss: t) }
        func joined(_ parts: [String?]) -> String? {
            let p = parts.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "・")
        }
        var out: [MinutesSection] = []
        func add(_ kind: MinutesSectionKind, _ rows: [MinutesRow], diagram: String? = nil) {
            guard !rows.isEmpty || diagram != nil else { return }
            out.append(MinutesSection(kind: kind, title: title(kind), symbol: symbol(kind), rows: rows, diagram: diagram))
        }
        func id(_ kind: MinutesSectionKind, _ i: Int) -> String { "\(kind.rawValue)-\(i)" }

        add(.attendees, m.attendees.enumerated().compactMap { i, a in
            clean(a.name).map { MinutesRow(id: id(.attendees, i), text: $0, secondary: clean(a.role), symbol: "person.fill") }
        })
        add(.agenda, m.agenda.enumerated().compactMap { i, a in
            guard let title = clean(a.title) ?? clean(a.body).map({ _ in "（無題）" }) else { return nil }
            return MinutesRow(id: id(.agenda, i), text: title, detail: clean(a.body), time: time(a.t))
        })
        add(.summary, m.summary.enumerated().compactMap { i, s in clean(s).map { MinutesRow(id: id(.summary, i), text: $0) } })
        add(.keyPoints, m.keyPoints.enumerated().compactMap { i, p in
            clean(p.text).map { MinutesRow(id: id(.keyPoints, i), text: $0, symbol: "circle.fill", symbolTone: .secondary, time: time(p.t)) }
        })
        add(.decisions, m.decisions.enumerated().compactMap { i, d in
            clean(d.text).map { MinutesRow(id: id(.decisions, i), text: $0, symbol: "checkmark.circle.fill", symbolTone: .green, time: time(d.t)) }
        })
        add(.insights, m.insights.enumerated().compactMap { i, p in
            clean(p.text).map { MinutesRow(id: id(.insights, i), text: $0, symbol: "lightbulb.fill", symbolTone: .yellow, time: time(p.t)) }
        })
        add(.questions, m.questions.enumerated().compactMap { i, q in
            clean(q.question).map {
                MinutesRow(id: id(.questions, i), text: $0, secondary: clean(q.askedBy), detail: clean(q.answer).map { "→ \($0)" },
                           badges: [resolvedBadge(q.isResolved)], symbol: "questionmark.circle", symbolTone: .secondary, time: time(q.t))
            }
        })
        add(.deadlines, m.deadlines.enumerated().compactMap { i, d in
            clean(d.description).map {
                MinutesRow(id: id(.deadlines, i), text: $0, secondary: joined([clean(d.date), clean(d.owner)]), secondaryTone: .red,
                           symbol: "calendar", symbolTone: .red, time: time(d.t))
            }
        })
        add(.followUps, m.followUps.enumerated().compactMap { i, p in
            clean(p.text).map { MinutesRow(id: id(.followUps, i), text: $0, symbol: "arrow.turn.down.right", symbolTone: .blue, time: time(p.t)) }
        })
        add(.risks, m.risks.enumerated().compactMap { i, r in
            clean(r.description).map {
                MinutesRow(id: id(.risks, i), text: $0, detail: clean(r.mitigation).map { "対策: \($0)" },
                           badges: [MinutesBadge(text: "重大度 \(levelText(r.severity))", tone: levelTone(r.severity))],
                           symbol: "exclamationmark.triangle.fill", symbolTone: levelTone(r.severity), time: time(r.t))
            }
        })
        add(.diagram, [], diagram: diagramSource(m.architectureDiagram))
        add(.actions, m.nextActions.enumerated().compactMap { i, a in
            clean(a.text).map {
                MinutesRow(id: id(.actions, i), text: $0,
                           secondary: joined([clean(a.owner).map { "担当 \($0)" }, clean(a.due).map { "期限 \($0)" }]),
                           badges: [MinutesBadge(text: levelText(a.priority), tone: levelTone(a.priority))],
                           time: time(a.t), priority: a.priority)
            }
        })
        return out
    }

    /// The action rows the filter lets through (すべて: every row, in order).
    public static func filter(_ rows: [MinutesRow], by filter: MinutesActionFilter) -> [MinutesRow] {
        guard let level = filter.level else { return rows }
        return rows.filter { $0.priority == level }
    }

    /// The transcript line a row's time jumps to: the same utterance the Vault link points at
    /// (`TranscriptMarkdown.linkTarget`): the last one containing the time, else the last that started before it,
    /// else the first. nil without utterances.
    public static func utteranceIndex(for time: TimelineTime, in utterances: [Utterance]) -> Int? {
        guard !utterances.isEmpty else { return nil }
        let candidates = utterances.indices.filter { utterances[$0].start.seconds.rounded(.down) <= time.seconds }
        let containing = candidates.last { utterances[$0].start <= time && (utterances[$0].end ?? utterances[$0].start) >= time }
        return containing ?? candidates.last ?? 0
    }
}
