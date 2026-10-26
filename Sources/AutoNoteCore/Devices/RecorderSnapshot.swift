import Foundation

public struct RecorderSnapshot: Equatable, Sendable, Codable {
    public var state: RecorderState
    public var meetingID: MeetingID?
    public var startedAt: Date?
    public var deviceName: String?
    /// Expiry of the countdown or the grace period.
    public var deadline: Date?
    public var isManual: Bool
    public var language: Language
    public var banner: String?

    public init(state: RecorderState, meetingID: MeetingID? = nil, startedAt: Date? = nil, deviceName: String? = nil,
                deadline: Date? = nil, isManual: Bool = false, language: Language, banner: String? = nil) {
        self.state = state; self.meetingID = meetingID; self.startedAt = startedAt; self.deviceName = deviceName
        self.deadline = deadline; self.isManual = isManual; self.language = language; self.banner = banner
    }

    /// Only the countdown can be cancelled; the grace period cannot (§5.9).
    public var canCancelCountdown: Bool { state == .countdown }

    public static func idle(language: Language) -> RecorderSnapshot { RecorderSnapshot(state: .idle, language: language) }

    /// `meetingID` needs an explicit key: the snake-case strategies map `meeting_id` to `meetingId`, not `meetingID`.
    private enum CodingKeys: String, CodingKey {
        case state, startedAt, deviceName, deadline, isManual, language, banner
        case meetingID = "meetingId"
    }
}
