import Foundation

public struct MinutesOutput: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var summary: [String]
    public var decisions: [Decision]
    public var agenda: [AgendaItem]
    public var nextActions: [NextAction]
    public var suggestedTerms: [String]

    public init(title: String, summary: [String], decisions: [Decision], agenda: [AgendaItem],
                nextActions: [NextAction], suggestedTerms: [String]) {
        self.title = title; self.summary = summary; self.decisions = decisions; self.agenda = agenda
        self.nextActions = nextActions; self.suggestedTerms = suggestedTerms
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

public struct NextAction: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var owner: String?
    public var due: String?
    public var t: String

    public init(text: String, owner: String? = nil, due: String? = nil, t: String) {
        self.text = text; self.owner = owner; self.due = due; self.t = t
    }

    public var time: TimelineTime? { TimelineTime(hhmmss: t) }

    private enum CodingKeys: String, CodingKey { case text, owner, due, t }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        t = try c.decode(String.self, forKey: .t)
    }

    /// The schema requires `owner` and `due`, so nil is written as `null`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(owner, forKey: .owner)
        try c.encode(due, forKey: .due)
        try c.encode(t, forKey: .t)
    }
}
