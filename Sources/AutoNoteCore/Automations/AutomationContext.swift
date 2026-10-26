import Foundation

/// What an automation is told about the event that fired it: as `AUTONOTE_*` environment variables and as JSON on stdin.
public struct AutomationContext: Equatable, Sendable {
    public var event: AutomationTrigger
    public var meetingID: MeetingID
    public var file: URL?
    public var title: String
    /// `YYYY-MM-DD`
    public var date: String
    /// `HH:MM`
    public var start: String
    public var minutesJSON: URL?

    public init(event: AutomationTrigger, meetingID: MeetingID, file: URL?, title: String, date: String,
                start: String, minutesJSON: URL?) {
        self.event = event
        self.meetingID = meetingID
        self.file = file
        self.title = title
        self.date = date
        self.start = start
        self.minutesJSON = minutesJSON
    }

    /// Absent `file` / `minutesJSON` become empty strings.
    public func environment() -> [String: String] {
        [
            "AUTONOTE_EVENT": event.rawValue,
            "AUTONOTE_MEETING_ID": meetingID.rawValue,
            "AUTONOTE_FILE": file?.path ?? "",
            "AUTONOTE_TITLE": title,
            "AUTONOTE_DATE": date,
            "AUTONOTE_START": start,
            "AUTONOTE_JSON": minutesJSON?.path ?? "",
        ]
    }

    /// Keys `event meeting_id file title date start json`; absent `file` / `json` are `null`.
    public func stdinJSON() throws -> Data {
        var data = try AutoNoteJSON.encoder().encode(StdinPayload(context: self))
        data.append(0x0A)
        return data
    }
}

private struct StdinPayload: Encodable {
    let context: AutomationContext

    private enum CodingKeys: String, CodingKey { case event, meetingId, file, title, date, start, json }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(context.event, forKey: .event)
        try c.encode(context.meetingID, forKey: .meetingId)
        if let file = context.file { try c.encode(file.path, forKey: .file) } else { try c.encodeNil(forKey: .file) }
        try c.encode(context.title, forKey: .title)
        try c.encode(context.date, forKey: .date)
        try c.encode(context.start, forKey: .start)
        if let json = context.minutesJSON { try c.encode(json.path, forKey: .json) } else { try c.encodeNil(forKey: .json) }
    }
}
