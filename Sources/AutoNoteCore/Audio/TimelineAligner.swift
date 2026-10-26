import Foundation

public struct Placement: Equatable, Sendable {
    /// Zero samples to write before `samples`.
    public var silenceBefore: Int
    public var samples: ArraySlice<Int16>

    public init(silenceBefore: Int, samples: ArraySlice<Int16>) {
        self.silenceBefore = silenceBefore; self.samples = samples
    }
}

/// Places chunks on the meeting timeline. `writtenEnd` follows the samples actually written,
/// not chunk timestamps, so small jitter never accumulates; a gap or overlap beyond `tolerance` is fixed at once.
public struct TimelineAligner: Sendable {
    public static let tolerance: Double = 0.05

    private let start: TimelineTime
    private var writtenSamples = 0
    public private(set) var writtenEnd: TimelineTime

    public init(start: TimelineTime) {
        self.start = start; self.writtenEnd = start
    }

    public mutating func place(_ chunk: AudioChunk) -> Placement {
        let d = chunk.start.seconds - writtenEnd.seconds
        var silence = 0
        var samples = chunk.samples[...]
        if d > Self.tolerance {
            silence = Int((d * AudioChunk.sampleRate).rounded())
        } else if d < -Self.tolerance {
            samples = samples.dropFirst(Int((-d * AudioChunk.sampleRate).rounded()))
        }
        advance(by: silence + samples.count)
        return Placement(silenceBefore: silence, samples: samples)
    }

    /// Number of zero samples needed to reach `end` (0 if already there).
    public mutating func padding(to end: TimelineTime) -> Int {
        let n = Int(((end.seconds - writtenEnd.seconds) * AudioChunk.sampleRate).rounded())
        guard n > 0 else { return 0 }
        advance(by: n)
        return n
    }

    private mutating func advance(by n: Int) {
        writtenSamples += n
        writtenEnd = TimelineTime(seconds: start.seconds + Double(writtenSamples) / AudioChunk.sampleRate)
    }
}
