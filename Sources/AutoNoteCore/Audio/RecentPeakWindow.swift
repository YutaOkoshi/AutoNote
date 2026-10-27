import Foundation

/// The loudest sample of one track over the last second, as `levels()` reports it.
public struct TrackLevel: Sendable, Equatable {
    public var track: Track
    public var peakDBFS: Double

    public init(track: Track, peakDBFS: Double) {
        self.track = track; self.peakDBFS = peakDBFS
    }
}

/// Chunk peaks of one track over the half-open window `(now − 1 s, now]` on the meeting timeline.
struct RecentPeakWindow: Sendable {
    static let window = 1.0

    private var entries: [(at: TimelineTime, peakDBFS: Double)] = []

    /// Records a chunk peak and drops entries that fell out of the window relative to `at`.
    mutating func observe(peakDBFS: Double, at: TimelineTime) {
        entries.removeAll { $0.at.seconds <= at.seconds - Self.window }
        entries.append((at, peakDBFS))
    }

    /// The largest peak in `(now − 1 s, now]`; `-infinity` when there is none.
    func peak(at now: TimelineTime) -> Double {
        let from = now.seconds - Self.window
        return entries.lazy
            .filter { $0.at.seconds > from && $0.at.seconds <= now.seconds }
            .map(\.peakDBFS)
            .max() ?? -.infinity
    }
}
