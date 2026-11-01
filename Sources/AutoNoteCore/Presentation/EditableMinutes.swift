import Foundation

/// One editable list item with a stable identity, so a row can be removed without index-based bindings.
public struct EditableItem<Value: Equatable & Sendable>: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var value: Value

    public init(value: Value) { self.id = UUID(); self.value = value }
}

/// `MinutesOutput` as the 編集 tab edits it: the list sections carry stable identities. Every key passes through,
/// so saving never drops what the editor does not show (`suggested_terms`, `schema_version`, the diagram).
public struct EditableMinutes: Equatable, Sendable {
    public var schemaVersion: Int
    public var title: String
    public var summary: [EditableItem<String>]
    public var decisions: [EditableItem<Decision>]
    public var agenda: [EditableItem<AgendaItem>]
    public var nextActions: [EditableItem<NextAction>]
    public var suggestedTerms: [String]
    public var attendees: [EditableItem<Attendee>]
    public var keyPoints: [EditableItem<MinutesPoint>]
    public var insights: [EditableItem<MinutesPoint>]
    public var questions: [EditableItem<MinutesQuestion>]
    public var deadlines: [EditableItem<Deadline>]
    public var followUps: [EditableItem<MinutesPoint>]
    public var risks: [EditableItem<Risk>]
    public var architectureDiagram: String?

    public init(_ m: MinutesOutput) {
        schemaVersion = m.schemaVersion
        title = m.title
        summary = m.summary.map { EditableItem(value: $0) }
        decisions = m.decisions.map { EditableItem(value: $0) }
        agenda = m.agenda.map { EditableItem(value: $0) }
        nextActions = m.nextActions.map { EditableItem(value: $0) }
        suggestedTerms = m.suggestedTerms
        attendees = m.attendees.map { EditableItem(value: $0) }
        keyPoints = m.keyPoints.map { EditableItem(value: $0) }
        insights = m.insights.map { EditableItem(value: $0) }
        questions = m.questions.map { EditableItem(value: $0) }
        deadlines = m.deadlines.map { EditableItem(value: $0) }
        followUps = m.followUps.map { EditableItem(value: $0) }
        risks = m.risks.map { EditableItem(value: $0) }
        architectureDiagram = m.architectureDiagram
    }

    public var minutes: MinutesOutput {
        MinutesOutput(title: title, summary: summary.map(\.value), decisions: decisions.map(\.value),
                      agenda: agenda.map(\.value), nextActions: nextActions.map(\.value), suggestedTerms: suggestedTerms,
                      attendees: attendees.map(\.value), keyPoints: keyPoints.map(\.value), insights: insights.map(\.value),
                      questions: questions.map(\.value), deadlines: deadlines.map(\.value), followUps: followUps.map(\.value),
                      risks: risks.map(\.value), architectureDiagram: architectureDiagram, schemaVersion: schemaVersion)
    }
}
