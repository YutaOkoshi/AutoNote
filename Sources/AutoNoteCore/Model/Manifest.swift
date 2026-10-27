import Foundation

public struct DeviceRef: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var uid: String
    public var transport: String

    public init(name: String, uid: String, transport: String) {
        self.name = name; self.uid = uid; self.transport = transport
    }
}

public struct Manifest: Codable, Equatable, Hashable, Sendable {
    public var id: MeetingID
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var source: MeetingSource
    public var device: DeviceRef?
    public var language: Language
    public var tracks: [TrackFile]
    public var pauses: [PauseInterval]
    public var bookmarks: [Bookmark]
    public var status: MeetingStatus
    public var silenceWarning: Bool
    public var autonoteVersion: String
    /// The meeting note last written to the Vault: its absolute path and title (nil when it had no title). The list
    /// falls back to these when the current output folder does not hold the note, so changing the output folder
    /// leaves the finished meeting's title and 「Finder で表示」 alone (the note stays in the old folder).
    public var notePath: String?
    public var noteTitle: String?

    public init(id: MeetingID, title: String?, startedAt: Date, endedAt: Date?, source: MeetingSource,
                device: DeviceRef?, language: Language, tracks: [TrackFile], pauses: [PauseInterval],
                bookmarks: [Bookmark], status: MeetingStatus, silenceWarning: Bool, autonoteVersion: String,
                notePath: String? = nil, noteTitle: String? = nil) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.source = source; self.device = device; self.language = language
        self.tracks = tracks; self.pauses = pauses; self.bookmarks = bookmarks
        self.status = status; self.silenceWarning = silenceWarning; self.autonoteVersion = autonoteVersion
        self.notePath = notePath; self.noteTitle = noteTitle
    }

    /// `endedAt - startedAt` in seconds; nil while still recording.
    public var duration: Double? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}
