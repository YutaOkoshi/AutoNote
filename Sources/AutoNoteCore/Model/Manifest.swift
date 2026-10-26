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

    public init(id: MeetingID, title: String?, startedAt: Date, endedAt: Date?, source: MeetingSource,
                device: DeviceRef?, language: Language, tracks: [TrackFile], pauses: [PauseInterval],
                bookmarks: [Bookmark], status: MeetingStatus, silenceWarning: Bool, autonoteVersion: String) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.source = source; self.device = device; self.language = language
        self.tracks = tracks; self.pauses = pauses; self.bookmarks = bookmarks
        self.status = status; self.silenceWarning = silenceWarning; self.autonoteVersion = autonoteVersion
    }

    /// `endedAt - startedAt` in seconds; nil while still recording.
    public var duration: Double? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}
