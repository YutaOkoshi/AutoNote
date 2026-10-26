import Foundation

public struct Utterance: Codable, Equatable, Hashable, Sendable {
    public var start: TimelineTime
    public var end: TimelineTime?
    public var speaker: Speaker
    public var text: String
    public var isFinal: Bool

    public init(start: TimelineTime, end: TimelineTime? = nil, speaker: Speaker, text: String, isFinal: Bool) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text; self.isFinal = isFinal
    }
}

public struct Transcript: Codable, Equatable, Hashable, Sendable {
    public var utterances: [Utterance]
    public var engine: String
    public var language: Language

    public init(utterances: [Utterance], engine: String, language: Language) {
        self.utterances = utterances; self.engine = engine; self.language = language
    }

    /// `transcript_engine` label used when the final pass failed and the live transcript stands in.
    public static func fallbackEngineLabel(live: String) -> String {
        "\(live)（確定版の失敗によりリアルタイム版で代用）"
    }
}

public struct Bookmark: Codable, Equatable, Hashable, Sendable {
    public var at: TimelineTime
    public var note: String?

    public init(at: TimelineTime, note: String? = nil) { self.at = at; self.note = note }
}

public struct PauseInterval: Codable, Equatable, Hashable, Sendable {
    public var start: TimelineTime
    public var end: TimelineTime?

    public init(start: TimelineTime, end: TimelineTime? = nil) { self.start = start; self.end = end }
}

public struct TrackFile: Codable, Equatable, Hashable, Sendable {
    public var track: Track
    public var relativePath: String
    public var startOffset: TimelineTime
    public var durationSeconds: Double?

    public init(track: Track, relativePath: String, startOffset: TimelineTime, durationSeconds: Double? = nil) {
        self.track = track; self.relativePath = relativePath; self.startOffset = startOffset; self.durationSeconds = durationSeconds
    }
}
