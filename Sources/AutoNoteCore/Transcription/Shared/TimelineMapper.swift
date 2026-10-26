import Foundation

/// Maps seconds of the audio actually received to meeting-timeline time, skipping pauses and dropouts.
public struct TimelineMapper: Sendable {
    private struct Segment: Sendable { var audioStart: Double; var timelineStart: Double }
    private static let jumpThreshold = 0.05

    private var segments: [Segment] = []
    private var samples = 0

    public init() {}

    public var audioSeconds: Double { Double(samples) / AudioChunk.sampleRate }

    public mutating func append(_ chunk: AudioChunk) {
        let audioNow = audioSeconds
        if let last = segments.last {
            let expected = last.timelineStart + (audioNow - last.audioStart)
            if chunk.start.seconds - expected >= Self.jumpThreshold - 1e-9 {
                segments.append(Segment(audioStart: audioNow, timelineStart: chunk.start.seconds))
            }
        } else {
            segments.append(Segment(audioStart: 0, timelineStart: chunk.start.seconds))
        }
        samples += chunk.samples.count
    }

    public func timeline(atAudioSeconds t: Double) -> TimelineTime {
        guard !segments.isEmpty else { return TimelineTime(seconds: t) }
        var lo = 0, hi = segments.count - 1
        while lo < hi {                               // last segment with audioStart <= t
            let mid = (lo + hi + 1) / 2
            if segments[mid].audioStart <= t { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        return TimelineTime(seconds: s.timelineStart + (t - s.audioStart))
    }
}
