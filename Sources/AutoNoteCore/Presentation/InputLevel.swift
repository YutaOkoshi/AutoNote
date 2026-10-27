import Foundation

/// What the recording meter shows: 0–5 bars, and whether the input has been quiet long enough to say
/// 「音を拾えていません」.
public struct InputLevel: Sendable, Equatable {
    /// 0...5
    public var bars: Int
    public var quiet: Bool

    public init(bars: Int, quiet: Bool) {
        self.bars = bars; self.quiet = quiet
    }
}

/// Turns the per-track peaks read on each 1-second tick into an `InputLevel`.
public struct InputLevelTracker: Sendable {
    /// The loudest track below this counts as a quiet tick.
    public static let quietThresholdDBFS = -60.0
    /// Consecutive quiet ticks while recording before `quiet` turns on.
    public static let quietTicks = 10
    private static let barThresholds: [Double] = [-60, -48, -36, -24, -12]

    private var quietCount = 0

    public init() {}

    /// Paused (or not recording) ticks reset the count and never report `quiet`.
    public mutating func observe(_ levels: [TrackLevel], recording: Bool) -> InputLevel {
        let loudest = levels.map(\.peakDBFS).max() ?? -.infinity
        if recording, loudest < Self.quietThresholdDBFS {
            quietCount += 1
        } else {
            quietCount = 0
        }
        return InputLevel(bars: Self.bars(peakDBFS: loudest), quiet: recording && quietCount >= Self.quietTicks)
    }

    /// The number of thresholds (−60, −48, −36, −24, −12 dBFS) the peak reaches.
    public static func bars(peakDBFS: Double) -> Int {
        barThresholds.filter { peakDBFS >= $0 }.count
    }
}
