import Foundation

public enum Speaker: String, Codable, Hashable, Sendable {
    case me, other, unknown

    public var displayName: String {
        switch self {
        case .me: "自分"
        case .other: "相手"
        case .unknown: "不明"
        }
    }
}

public enum Language: String, Codable, Hashable, Sendable { case auto, ja, en }

public enum Track: String, Codable, Hashable, Sendable { case mic, system }

public enum MeetingStatus: String, Codable, Hashable, Sendable {
    case recording, recorded, transcribing, transcribed, generating
    case minutesGenerated = "minutes_generated"
    case transcriptOnly = "transcript_only"
    case failed
    case tooShort = "too_short"
}

public enum MeetingSource: String, Codable, Hashable, Sendable { case live, imported }
