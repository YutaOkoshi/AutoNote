import Foundation

/// The commands the `autonote` CLI can send to the app (requirements §16, one-to-one).
public enum IPCCommand: String, Codable, Sendable, CaseIterable {
    case start, stop, pause, resume, bookmark, status, list, latest
    case `import`
    case regenerate
    case automationsList = "automations.list"
    case automationsRun = "automations.run"
}

public struct IPCArgs: Codable, Equatable, Sendable {
    public var lang: Language?
    public var note: String?
    public var since: String?
    public var open: Bool?
    public var file: String?
    public var meetingID: String?
    public var name: String?

    public init(lang: Language? = nil, note: String? = nil, since: String? = nil, open: Bool? = nil,
                file: String? = nil, meetingID: String? = nil, name: String? = nil) {
        self.lang = lang
        self.note = note
        self.since = since
        self.open = open
        self.file = file
        self.meetingID = meetingID
        self.name = name
    }

    // `meetingID` would snake-case to `meeting_i_d`; pin the key.
    private enum CodingKeys: String, CodingKey {
        case lang, note, since, open, file, name
        case meetingID = "meetingId"
    }
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public var cmd: IPCCommand
    public var args: IPCArgs
    public var id: Int

    public init(cmd: IPCCommand, args: IPCArgs = IPCArgs(), id: Int) {
        self.cmd = cmd
        self.args = args
        self.id = id
    }
}

public enum IPCErrorCode: String, Codable, Sendable {
    case notRecording = "not_recording"
    case alreadyRecording = "already_recording"
    case notFound = "not_found"
    case invalidArgs = "invalid_args"
    case unknownCommand = "unknown_command"
    case badRequest = "bad_request"
    case failed
}

public struct IPCError: Codable, Equatable, Sendable, Error {
    public var code: IPCErrorCode
    public var message: String

    public init(code: IPCErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct IPCResult: Codable, Equatable, Sendable {
    public var status: StatusResult?
    public var meetings: [MeetingRow]?
    public var path: String?
    public var meetingID: String?
    public var bookmark: Bookmark?
    public var automations: [AutomationSummary]?
    public var run: AutomationRunRecord?

    public init(status: StatusResult? = nil, meetings: [MeetingRow]? = nil, path: String? = nil, meetingID: String? = nil,
                bookmark: Bookmark? = nil, automations: [AutomationSummary]? = nil, run: AutomationRunRecord? = nil) {
        self.status = status
        self.meetings = meetings
        self.path = path
        self.meetingID = meetingID
        self.bookmark = bookmark
        self.automations = automations
        self.run = run
    }

    private enum CodingKeys: String, CodingKey {
        case status, meetings, path, bookmark, automations, run
        case meetingID = "meetingId"
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var id: Int?
    public var ok: Bool
    public var result: IPCResult?
    public var error: IPCError?

    public init(id: Int?, ok: Bool, result: IPCResult? = nil, error: IPCError? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ id: Int, _ r: IPCResult) -> IPCResponse { IPCResponse(id: id, ok: true, result: r) }
    public static func failure(_ id: Int?, _ e: IPCError) -> IPCResponse { IPCResponse(id: id, ok: false, error: e) }
}
