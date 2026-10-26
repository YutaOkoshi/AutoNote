import Foundation

/// One transcribed audio file; utterance times are relative to the file start.
public struct TrackTranscription: Codable, Equatable, Sendable {
    public var file: TrackFile
    public var utterances: [Utterance]

    public init(file: TrackFile, utterances: [Utterance]) {
        self.file = file; self.utterances = utterances
    }
}

/// Merges per-file transcriptions onto the meeting timeline (spec §5.4).
public enum TranscriptMerger {
    public static func merge(_ parts: [TrackTranscription], source: MeetingSource) -> [Utterance] {
        var entries: [(utterance: Utterance, rank: Int, order: Int)] = []
        for part in parts {
            let speaker: Speaker = source == .imported ? .unknown : (part.file.track == .mic ? .me : .other)
            let rank = part.file.track == .mic ? 0 : 1
            for var utterance in part.utterances {
                utterance.start = utterance.start + part.file.startOffset
                utterance.end = utterance.end.map { $0 + part.file.startOffset }
                utterance.speaker = speaker
                entries.append((utterance, rank, entries.count))
            }
        }
        return entries.sorted {
            if $0.utterance.start != $1.utterance.start { return $0.utterance.start < $1.utterance.start }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.order < $1.order
        }.map(\.utterance)
    }
}
