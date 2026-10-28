import Foundation

/// One window of a windowed batch transcription. Ranges are samples from the start of the file (16 kHz).
public struct BatchWindow: Equatable, Sendable {
    /// Position of the window in the plan, from 0.
    public var index: Int
    /// The samples handed to whisper.
    public var read: Range<Int>
    /// The samples whose segments this window keeps.
    public var owned: Range<Int>
    /// Whether this is the final window of the file.
    public var isLast: Bool

    public init(index: Int, read: Range<Int>, owned: Range<Int>, isLast: Bool) {
        self.index = index
        self.read = read
        self.owned = owned
        self.isLast = isLast
    }

    /// Whether a segment whose midpoint is `m` seconds from the start of the file belongs to this window.
    /// A bound applies only on a side where the read overlaps the neighbour (a hard cut); at a silence cut, the file
    /// start and the file end the window keeps everything, since whisper may put a segment end past the audio.
    /// A midpoint on a hard cut goes to the later window.
    public func owns(midpointSeconds m: Double) -> Bool {
        let hardBefore = read.lowerBound < owned.lowerBound
        let hardAfter = read.upperBound > owned.upperBound
        return (!hardBefore || m >= Double(owned.lowerBound) / 16_000) && (!hardAfter || m < Double(owned.upperBound) / 16_000)
    }
}

/// Splits a 16 kHz mono file into nominal-length windows. Each cut is at the centre of the longest silence in the
/// `lookback` before the nominal end; with no silence it is a hard cut at the nominal end, read with `overlap`
/// on both sides. A remainder of at most `nominal + tailMerge` stays in the last window.
public struct BatchWindowPlanner: Sendable {
    /// Lengths in seconds.
    public struct Config: Equatable, Sendable {
        public var nominal: Double
        public var lookback: Double
        public var overlap: Double
        public var tailMerge: Double

        public init(nominal: Double = 600, lookback: Double = 60, overlap: Double = 5, tailMerge: Double = 120) {
            self.nominal = nominal
            self.lookback = lookback
            self.overlap = overlap
            self.tailMerge = tailMerge
        }
    }

    private static let sampleRate = 16_000.0

    private let config: Config

    public init(config: Config = .init()) {
        precondition(config.nominal > 0 && config.lookback >= 0 && config.overlap >= 0 && config.tailMerge >= 0,
                     "nominal must be positive and lookback, overlap and tailMerge non-negative")
        precondition(config.lookback <= config.nominal, "lookback must not exceed nominal")
        precondition(config.overlap < config.nominal, "overlap must be shorter than nominal")
        self.config = config
    }

    /// Plans the windows of a file of `sampleCount` samples. `read` returns the samples of a range (used only for
    /// the lookback searches).
    public func plan(sampleCount: Int, read: (Range<Int>) throws -> [Int16]) rethrows -> [BatchWindow] {
        let nominal = Self.samples(config.nominal)
        let lookback = Self.samples(config.lookback)
        let overlap = Self.samples(config.overlap)
        let tailMerge = Self.samples(config.tailMerge)
        var windows: [BatchWindow] = []
        var start = 0
        var previousWasHard = false
        while true {
            let readStart = previousWasHard ? max(0, start - overlap) : start
            if sampleCount - start <= nominal + tailMerge {
                windows.append(BatchWindow(index: windows.count, read: readStart..<sampleCount,
                                           owned: start..<sampleCount, isLast: true))
                return windows
            }
            let nominalEnd = start + nominal
            let search = (nominalEnd - lookback)..<nominalEnd
            let cut: Int
            let hard: Bool
            let readEnd: Int
            if let silence = SilenceDetector().longestSilence(in: try read(search)) {
                cut = search.lowerBound + (silence.lowerBound + silence.upperBound) / 2
                hard = false
                readEnd = cut
            } else {
                cut = nominalEnd
                hard = true
                readEnd = min(sampleCount, cut + overlap)
            }
            windows.append(BatchWindow(index: windows.count, read: readStart..<readEnd, owned: start..<cut, isLast: false))
            start = cut
            previousWasHard = hard
        }
    }

    private static func samples(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }
}
