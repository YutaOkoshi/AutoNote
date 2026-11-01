import Foundation

/// The structured minutes (`minutes.json`, schema v2). The six v1 keys keep their names and types (Automations read
/// them through `AUTONOTE_JSON`); the v2 keys decode as empty / nil when absent, so a v1 file still reads.
/// Encoding always writes every key (nil as `null`), as the JSON Schema requires.
public struct MinutesOutput: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    /// 1 when the file has no `schema_version` (written before v2). Kept as read when re-encoded.
    public var schemaVersion: Int
    public var title: String
    public var summary: [String]
    public var decisions: [Decision]
    public var agenda: [AgendaItem]
    public var nextActions: [NextAction]
    public var suggestedTerms: [String]
    public var attendees: [Attendee]
    public var keyPoints: [MinutesPoint]
    public var insights: [MinutesPoint]
    public var questions: [MinutesQuestion]
    public var deadlines: [Deadline]
    public var followUps: [MinutesPoint]
    public var risks: [Risk]
    /// Mermaid `graph TD/LR` source, only when the meeting discussed a system layout or data flow.
    public var architectureDiagram: String?

    public init(title: String, summary: [String], decisions: [Decision], agenda: [AgendaItem],
                nextActions: [NextAction], suggestedTerms: [String],
                attendees: [Attendee] = [], keyPoints: [MinutesPoint] = [], insights: [MinutesPoint] = [],
                questions: [MinutesQuestion] = [], deadlines: [Deadline] = [], followUps: [MinutesPoint] = [],
                risks: [Risk] = [], architectureDiagram: String? = nil,
                schemaVersion: Int = MinutesOutput.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.title = title; self.summary = summary; self.decisions = decisions; self.agenda = agenda
        self.nextActions = nextActions; self.suggestedTerms = suggestedTerms
        self.attendees = attendees; self.keyPoints = keyPoints; self.insights = insights; self.questions = questions
        self.deadlines = deadlines; self.followUps = followUps; self.risks = risks
        self.architectureDiagram = architectureDiagram
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, title, summary, decisions, agenda, nextActions, suggestedTerms
        case attendees, keyPoints, insights, questions, deadlines, followUps, risks, architectureDiagram
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode([String].self, forKey: .summary)
        decisions = try c.decode([Decision].self, forKey: .decisions)
        agenda = try c.decode([AgendaItem].self, forKey: .agenda)
        nextActions = try c.decode([NextAction].self, forKey: .nextActions)
        suggestedTerms = try c.decode([String].self, forKey: .suggestedTerms)
        attendees = try c.decodeIfPresent([Attendee].self, forKey: .attendees) ?? []
        keyPoints = try c.decodeIfPresent([MinutesPoint].self, forKey: .keyPoints) ?? []
        insights = try c.decodeIfPresent([MinutesPoint].self, forKey: .insights) ?? []
        questions = try c.decodeIfPresent([MinutesQuestion].self, forKey: .questions) ?? []
        deadlines = try c.decodeIfPresent([Deadline].self, forKey: .deadlines) ?? []
        followUps = try c.decodeIfPresent([MinutesPoint].self, forKey: .followUps) ?? []
        risks = try c.decodeIfPresent([Risk].self, forKey: .risks) ?? []
        architectureDiagram = try c.decodeIfPresent(String.self, forKey: .architectureDiagram)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(decisions, forKey: .decisions)
        try c.encode(agenda, forKey: .agenda)
        try c.encode(nextActions, forKey: .nextActions)
        try c.encode(suggestedTerms, forKey: .suggestedTerms)
        try c.encode(attendees, forKey: .attendees)
        try c.encode(keyPoints, forKey: .keyPoints)
        try c.encode(insights, forKey: .insights)
        try c.encode(questions, forKey: .questions)
        try c.encode(deadlines, forKey: .deadlines)
        try c.encode(followUps, forKey: .followUps)
        try c.encode(risks, forKey: .risks)
        try c.encode(architectureDiagram, forKey: .architectureDiagram)
    }
}

public struct Decision: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var t: String
    public init(text: String, t: String) { self.text = text; self.t = t }
    public var time: TimelineTime? { TimelineTime(hhmmss: t) }
}

public struct AgendaItem: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var body: String
    public var t: String
    public init(title: String, body: String, t: String) { self.title = title; self.body = body; self.t = t }
    public var time: TimelineTime? { TimelineTime(hhmmss: t) }
}

/// `high` / `medium` / `low`, shared by `next_actions[].priority` and `risks[].severity`.
/// An unknown value (a hand-edited file) reads as `medium` instead of failing the whole file.
public enum MinutesLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case high, medium, low

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MinutesLevel(rawValue: raw) ?? .medium
    }
}

public struct NextAction: Codable, Equatable, Hashable, Sendable {
    /// What a v1 file (no `priority`) reads as.
    public static let defaultPriority = MinutesLevel.medium

    public var text: String
    public var owner: String?
    public var due: String?
    public var t: String
    public var priority: MinutesLevel

    public init(text: String, owner: String? = nil, due: String? = nil, t: String,
                priority: MinutesLevel = NextAction.defaultPriority) {
        self.text = text; self.owner = owner; self.due = due; self.t = t; self.priority = priority
    }

    public var time: TimelineTime? { TimelineTime(hhmmss: t) }

    private enum CodingKeys: String, CodingKey { case text, owner, due, t, priority }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        t = try c.decode(String.self, forKey: .t)
        priority = try c.decodeIfPresent(MinutesLevel.self, forKey: .priority) ?? Self.defaultPriority
    }

    /// The schema requires `owner` and `due`, so nil is written as `null`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(owner, forKey: .owner)
        try c.encode(due, forKey: .due)
        try c.encode(t, forKey: .t)
        try c.encode(priority, forKey: .priority)
    }
}

/// `attendees[]`: guessed from the speaker labels and what was said; the label itself when unknown.
public struct Attendee: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var role: String?

    public init(name: String, role: String? = nil) { self.name = name; self.role = role }

    private enum CodingKeys: String, CodingKey { case name, role }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(String.self, forKey: .role)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(role, forKey: .role)
    }
}

/// `key_points[]`, `insights[]` and `follow_ups[]`: a line with the time of the utterance it rests on.
public struct MinutesPoint: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var t: String
    public init(text: String, t: String) { self.text = text; self.t = t }
    public var time: TimelineTime? { TimelineTime(hhmmss: t) }
}

/// `questions[]`.
public struct MinutesQuestion: Codable, Equatable, Hashable, Sendable {
    public var question: String
    public var askedBy: String?
    public var isResolved: Bool
    public var answer: String?
    public var t: String

    public init(question: String, askedBy: String? = nil, isResolved: Bool, answer: String? = nil, t: String) {
        self.question = question; self.askedBy = askedBy; self.isResolved = isResolved; self.answer = answer; self.t = t
    }

    public var time: TimelineTime? { TimelineTime(hhmmss: t) }

    private enum CodingKeys: String, CodingKey { case question, askedBy, isResolved, answer, t }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        askedBy = try c.decodeIfPresent(String.self, forKey: .askedBy)
        isResolved = try c.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        t = try c.decode(String.self, forKey: .t)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(question, forKey: .question)
        try c.encode(askedBy, forKey: .askedBy)
        try c.encode(isResolved, forKey: .isResolved)
        try c.encode(answer, forKey: .answer)
        try c.encode(t, forKey: .t)
    }
}

/// `deadlines[]`: a date not tied to an action (an event day, a cut-off). An action's own due date is `next_actions[].due`.
public struct Deadline: Codable, Equatable, Hashable, Sendable {
    public var description: String
    public var date: String
    public var owner: String?
    public var t: String

    public init(description: String, date: String, owner: String? = nil, t: String) {
        self.description = description; self.date = date; self.owner = owner; self.t = t
    }

    public var time: TimelineTime? { TimelineTime(hhmmss: t) }

    private enum CodingKeys: String, CodingKey { case description, date, owner, t }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try c.decode(String.self, forKey: .description)
        date = try c.decode(String.self, forKey: .date)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        t = try c.decode(String.self, forKey: .t)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .description)
        try c.encode(date, forKey: .date)
        try c.encode(owner, forKey: .owner)
        try c.encode(t, forKey: .t)
    }
}

/// `risks[]`.
public struct Risk: Codable, Equatable, Hashable, Sendable {
    public var description: String
    public var severity: MinutesLevel
    public var mitigation: String?
    public var t: String

    public init(description: String, severity: MinutesLevel, mitigation: String? = nil, t: String) {
        self.description = description; self.severity = severity; self.mitigation = mitigation; self.t = t
    }

    public var time: TimelineTime? { TimelineTime(hhmmss: t) }

    private enum CodingKeys: String, CodingKey { case description, severity, mitigation, t }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try c.decode(String.self, forKey: .description)
        severity = try c.decode(MinutesLevel.self, forKey: .severity)
        mitigation = try c.decodeIfPresent(String.self, forKey: .mitigation)
        t = try c.decode(String.self, forKey: .t)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .description)
        try c.encode(severity, forKey: .severity)
        try c.encode(mitigation, forKey: .mitigation)
        try c.encode(t, forKey: .t)
    }
}
