/// Decides when a live whisper window is decoded (all values are seconds of received audio).
/// Leading silence is trimmed: while the window has no speech frame its start follows "now", so
/// `windowStart` lands on the first speech frame. Frames are classified like `SilenceDetector`'s
/// (20 ms, RMS ≥ 0.01 is speech). In a window opened by a hard cut, speech inside the overlap does not
/// count toward `minSpeech` (`OverlapTrimmer` always drops those tokens). Public only so `WhisperLiveTranscriber.init` can take a `Config`.
public struct ChunkPlanner: Sendable {
    public struct Config: Sendable {
        public var windowMax: Double
        public var overlap: Double
        public var partialEvery: Double
        public var minSpeech: Double

        public init(windowMax: Double = 8.0, overlap: Double = 1.0, partialEvery: Double = 2.0, minSpeech: Double = 0.3) {
            self.windowMax = windowMax; self.overlap = overlap; self.partialEvery = partialEvery; self.minSpeech = minSpeech
        }
    }

    enum Action: Equatable, Sendable {
        case partial(from: Double, to: Double)
        case commit(from: Double, to: Double, nextFrom: Double)
        case skip(from: Double, to: Double)
    }

    private static let frameSamples = 320
    private static let framesPerSecond = 50.0
    private static let threshold = 0.01
    private static let utteranceEndSilence = 0.8

    private let windowMaxFrames: Int
    private let overlapFrames: Int
    private let partialFrames: Int
    private let minSpeechFrames: Int

    private var detector: SilenceDetector
    private var pending: [Int16] = []
    private var totalSamples = 0
    private var now = 0                 // frames classified so far
    private var windowStart = 0         // frame
    private var lastPartial = 0         // frame
    private var overlapEnd = 0          // frame; speech before it is the previous window's overlap
    private var flags: [Bool] = []      // speech flag of each frame from `flagsBase`
    private var flagsBase = 0

    init(config: Config = .init()) {
        func frames(_ s: Double) -> Int { Int((s * Self.framesPerSecond).rounded()) }
        windowMaxFrames = frames(config.windowMax)
        overlapFrames = frames(config.overlap)
        partialFrames = frames(config.partialEvery)
        minSpeechFrames = frames(config.minSpeech)
        detector = SilenceDetector(threshold: Self.threshold, minSilence: Self.utteranceEndSilence, minSpeech: config.minSpeech)
    }

    /// Start of the current window; audio before it is never decoded again.
    var windowStartSeconds: Double { Self.seconds(windowStart) }

    mutating func ingest(_ samples: [Int16]) -> [Action] {
        pending.append(contentsOf: samples)
        totalSamples += samples.count
        var actions: [Action] = []
        var offset = 0
        while pending.count - offset >= Self.frameSamples {
            let frame = Array(pending[offset..<(offset + Self.frameSamples)])
            offset += Self.frameSamples
            let boundaries = detector.process(frame)
            step(isSpeech: Self.rms(frame) >= Self.threshold, boundaries: boundaries, into: &actions)
        }
        pending.removeFirst(offset)
        return actions
    }

    /// Ends the stream: the remaining window (including a trailing partial frame) is committed.
    mutating func flush() -> [Action] {
        let speech = countedSpeech(until: now)
        let from = Self.seconds(windowStart)
        let to = Double(totalSamples) / PCMAudio.sampleRate
        pending.removeAll()
        windowStart = now
        lastPartial = now
        trimFlags()
        if speech == 0 || to <= from { return [] }
        return speech < minSpeechFrames ? [.skip(from: from, to: to)] : [.commit(from: from, to: to, nextFrom: to)]
    }

    private mutating func step(isSpeech: Bool, boundaries: [Double], into actions: inout [Action]) {
        flags.append(isSpeech)
        now += 1
        if !isSpeech, speechFrames(windowStart..<now) == 0 {                       // 先頭の無音を落とす
            windowStart = now
            trimFlags()
        }

        for boundary in boundaries {
            let end = Int((boundary * Self.framesPerSecond).rounded())
            if end > windowStart {
                close(at: end, nextFrom: end, into: &actions)              // 無音で切るので重ねない
                return
            }
        }
        if now - windowStart >= windowMaxFrames {
            let end = windowStart + windowMaxFrames
            close(at: end, nextFrom: end - overlapFrames, into: &actions)  // 強制で切るときは重ねる
            return
        }
        if now - max(windowStart, lastPartial) >= partialFrames, countedSpeech(until: now) >= minSpeechFrames {
            actions.append(.partial(from: Self.seconds(windowStart), to: Self.seconds(now)))
            lastPartial = now
        }
    }

    private mutating func close(at end: Int, nextFrom: Int, into actions: inout [Action]) {
        let from = Self.seconds(windowStart), to = Self.seconds(end)
        var next = nextFrom
        if countedSpeech(until: end) >= minSpeechFrames {
            actions.append(.commit(from: from, to: to, nextFrom: Self.seconds(nextFrom)))
        } else {
            actions.append(.skip(from: from, to: to))                      // 無音を whisper に渡さない
            next = end
        }
        overlapEnd = end                                                   // 重なりの発話は次の窓で数えない
        windowStart = next
        if speechFrames(windowStart..<now) == 0 { windowStart = now }
        lastPartial = windowStart
        trimFlags()
    }

    /// Speech frames of the current window before `end`, leaving out the previous window's overlap.
    private func countedSpeech(until end: Int) -> Int {
        let from = max(windowStart, overlapEnd)
        return from < end ? speechFrames(from..<end) : 0
    }

    private func speechFrames(_ range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        var count = 0
        for i in range where flags[i - flagsBase] { count += 1 }
        return count
    }

    private mutating func trimFlags() {
        let drop = windowStart - flagsBase
        guard drop > 0 else { return }
        flags.removeFirst(drop)
        flagsBase = windowStart
    }

    private static func seconds(_ frames: Int) -> Double { Double(frames) / framesPerSecond }

    private static func rms(_ frame: [Int16]) -> Double {
        var sum = 0.0
        for s in frame {
            let v = Double(s) / 32_768
            sum += v * v
        }
        return (sum / Double(frame.count)).squareRoot()
    }
}
