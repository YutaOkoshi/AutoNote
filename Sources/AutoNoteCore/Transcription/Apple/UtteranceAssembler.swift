import Foundation

/// One result from an Apple speech module, in seconds of audio fed to the analyzer.
public struct RecognizedSegment: Equatable, Sendable {
    public var audioStart: Double
    public var audioEnd: Double
    public var text: String
    public var isFinal: Bool

    public init(audioStart: Double, audioEnd: Double, text: String, isFinal: Bool) {
        self.audioStart = audioStart; self.audioEnd = audioEnd; self.text = text; self.isFinal = isFinal
    }
}

/// Turns module results into `Utterance`s on the meeting timeline.
/// Apple's volatile results can move the front of their range, so the first result after a final
/// fixes the utterance's start; every result up to and including the next final reuses it
/// (consumers overwrite partials by `start`, overview §4). The final adds `end` and releases the start.
struct UtteranceAssembler: Sendable {
    private var anchor: Double?

    init() {}

    mutating func consume(_ r: RecognizedSegment, mapper: TimelineMapper) -> Utterance {
        let startSeconds = anchor ?? r.audioStart
        anchor = r.isFinal ? nil : startSeconds
        return Utterance(start: mapper.timeline(atAudioSeconds: startSeconds),
                         end: r.isFinal ? mapper.timeline(atAudioSeconds: r.audioEnd) : nil,
                         speaker: .unknown, text: r.text, isFinal: r.isFinal)
    }
}
