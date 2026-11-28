import Foundation
import os
import Synchronization

/// Realtime transcription with whisper by re-decoding a sliding window (`ChunkPlanner`).
/// A window's partials and its final share one `start`, so consumers overwrite by `start`.
/// One decode runs at a time: commits run in order and are never dropped; at most one partial waits,
/// a newer partial replacing the waiting one. A failed decode is logged and yields empty text
/// (an empty final still goes out so the consumer removes that window's partial).
///
/// Nothing bounds the commits that wait: a decoder slower than the audio falls behind for as long as the recording
/// runs. That backlog is only counted and logged here (`Backlog`); no window is dropped, thinned out or decoded
/// with another model because of it.
public actor WhisperLiveTranscriber: LiveTranscriber {
    /// The commits not decoded yet (the one being decoded, plus those waiting) and how much audio waits behind the
    /// oldest of them: from its end to the end of the newest, in seconds of received audio.
    /// Each further commit adds one and its stretch of audio (7 s for back-to-back windows of continuous speech).
    /// This is the queue of commits only: the time the decoder spends on the window in work, and on the partials
    /// in between, is not in it. So a small depth does not mean the text is on time. Measured with bursts of
    /// speech and a decode of 3.5 s: finals 8–11 s late at a worst depth of 2 and a worst lag of 3.6 s. With
    /// continuous speech and a decoder that keeps up the worst is a depth of 1 and a lag of 0.
    public struct Backlog: Sendable, Equatable {
        public var depth: Int
        public var lagSeconds: Double

        public init(depth: Int = 0, lagSeconds: Double = 0) {
            self.depth = depth; self.lagSeconds = lagSeconds
        }

        fileprivate mutating func raise(to other: Backlog) {
            depth = max(depth, other.depth)
            lagSeconds = max(lagSeconds, other.lagSeconds)
        }
    }

    /// Writes to the unified log (subsystem `com.yutaokoshi.autonote`, category `WhisperLiveTranscriber`) at
    /// `notice`, so `log show` still has the lines after the recording.
    public static let systemLog: @Sendable (String) -> Void = { message in
        logger.notice("\(message, privacy: .public)")
    }

    /// The first backlog line comes when more than three commits wait; the next ones each time the depth doubles.
    static let firstBacklogReport = 4

    private struct Job: Sendable {
        var from: Double
        var to: Double
        var samples: [Int16]
        var start: TimelineTime
        var end: TimelineTime?
        var dropBefore: Double
        var isFinal: Bool
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "WhisperLiveTranscriber")

    private let core: any WhisperCore
    private var planner: ChunkPlanner
    private var mapper = TimelineMapper()
    private var buffer: [Int16] = []
    private var bufferStart = 0                                 // audio sample index of `buffer[0]`
    private var overlapWindow: (from: Double, drop: Double)?    // window opened by a hard cut
    private var language: Language = .ja
    private var prompt: String?
    private var continuation: AsyncStream<Utterance>.Continuation?
    private var started = false
    private var accepting = false
    private var finishing: Task<Void, Never>?
    private var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private let log: @Sendable (String) -> Void
    private var track: Track?                                   // of the audio fed; names the track in the log
    private var decoding: (to: Double, isFinal: Bool)?
    private var nextBacklogReport = WhisperLiveTranscriber.firstBacklogReport
    /// The deepest backlog and the longest lag of this recording so far (the stop line and `dev transcribe`).
    public private(set) var worstBacklog = Backlog()
    /// The same since the queue was last empty: what the `cleared` line reports, so each backlog shows its own size.
    private var peakBacklog = Backlog()

    /// `log` gets the backlog lines (track, depth and seconds; never the text).
    public init(core: any WhisperCore, config: ChunkPlanner.Config = .init(),
                log: @escaping @Sendable (String) -> Void = WhisperLiveTranscriber.systemLog) {
        self.core = core
        planner = ChunkPlanner(config: config)
        self.log = log
    }

    public func start(language: Language, hints: [String]) async throws -> AsyncStream<Utterance> {
        guard !started else { throw TranscriptionError.engineUnavailable("already started") }
        started = true
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.language = language
        prompt = WhisperPrompt.make(hints: hints)
        self.continuation = continuation
        accepting = true
        return stream
    }

    public func feed(_ chunk: AudioChunk) async {
        guard accepting else { return }
        track = chunk.track
        mapper.append(chunk)
        buffer.append(contentsOf: chunk.samples)
        schedule(planner.ingest(chunk.samples))
    }

    /// Decodes what is left and ends the stream. Later (or concurrent) calls wait for the same ending.
    /// The stop line is written here, before the wait: how far behind the decoder is when this is called (for the
    /// system track that is after the microphone's rest was decoded, see `LiveFeed.finish`), and the recording's worst.
    public func finish() async {
        if accepting {
            accepting = false
            schedule(planner.flush())
            if let track {
                let now = backlog()
                log("live backlog at stop: track=\(track.rawValue) depth=\(now.depth) lag=\(Self.seconds(now.lagSeconds))s "
                    + "max_depth=\(worstBacklog.depth) max_lag=\(Self.seconds(worstBacklog.lagSeconds))s")
            }
            finishing = Task {
                while let running = worker { await running.value }
                continuation?.finish()
                continuation = nil
            }
        }
        await finishing?.value
    }

    private func schedule(_ actions: [ChunkPlanner.Action]) {
        for action in actions {
            switch action {
            case let .partial(from, to):
                jobs.removeAll { !$0.isFinal }                      // 古い partial は捨てて最新だけ回す
                jobs.append(job(from: from, to: to, isFinal: false))
            case let .commit(from, to, nextFrom):
                jobs.append(job(from: from, to: to, isFinal: true))
                overlapWindow = nextFrom < to ? (nextFrom, to - nextFrom) : nil
            case .skip:
                overlapWindow = nil
            }
        }
        let keep = max(0, sampleIndex(planner.windowStartSeconds) - bufferStart)   // 窓より前の音声は二度と使わない
        if keep > 0 {
            buffer.removeFirst(min(keep, buffer.count))
            bufferStart += keep
        }
        noteBacklog()
        if worker == nil, !jobs.isEmpty { worker = Task { await drain() } }
    }

    private func backlog() -> Backlog {
        var ends = jobs.filter(\.isFinal).map(\.to)                 // in the order they will be decoded
        if let decoding, decoding.isFinal { ends.insert(decoding.to, at: 0) }
        guard let oldest = ends.first, let newest = ends.last else { return Backlog() }
        return Backlog(depth: ends.count, lagSeconds: max(0, newest - oldest))
    }

    /// Called after every `schedule` (so, for each chunk fed): keeps the worst values and writes a line at depths
    /// 4, 8, 16, …
    private func noteBacklog() {
        let now = backlog()
        worstBacklog.raise(to: now)
        peakBacklog.raise(to: now)
        guard now.depth >= nextBacklogReport else { return }
        while nextBacklogReport <= now.depth { nextBacklogReport *= 2 }
        log("live backlog: track=\(track?.rawValue ?? "-") depth=\(now.depth) lag=\(Self.seconds(now.lagSeconds))s")
    }

    /// Called after each decode: once no commit is left, a backlog is over. If it was reported, a line says how far
    /// it went (this backlog only; the worst of the recording is in the stop line), and the count starts again.
    private func noteBacklogCleared() {
        guard backlog().depth == 0 else { return }
        let peak = peakBacklog
        peakBacklog = Backlog()
        guard nextBacklogReport > Self.firstBacklogReport else { return }
        nextBacklogReport = Self.firstBacklogReport
        log("live backlog cleared: track=\(track?.rawValue ?? "-") max_depth=\(peak.depth) "
            + "max_lag=\(Self.seconds(peak.lagSeconds))s")
    }

    private static func seconds(_ s: Double) -> String { String(format: "%.1f", s) }

    private func job(from: Double, to: Double, isFinal: Bool) -> Job {
        let lo = min(buffer.count, max(0, sampleIndex(from) - bufferStart))
        let hi = min(buffer.count, max(lo, sampleIndex(to) - bufferStart))
        let drop = overlapWindow.map { abs($0.from - from) < 1e-9 ? $0.drop : 0 } ?? 0
        return Job(from: from, to: to, samples: Array(buffer[lo..<hi]), start: mapper.timeline(atAudioSeconds: from),
                   end: isFinal ? mapper.timeline(atAudioSeconds: to) : nil, dropBefore: drop, isFinal: isFinal)
    }

    private func drain() async {
        while !jobs.isEmpty {
            let next = jobs.removeFirst()
            decoding = (next.to, next.isFinal)
            let text = await decode(next)
            decoding = nil
            noteBacklogCleared()                                    // before the yield: a reader of the final sees the line
            if next.isFinal || !text.isEmpty {                      // 空の確定は部分結果ごと消すために流す
                continuation?.yield(Utterance(start: next.start, end: next.end, speaker: .unknown, text: text, isFinal: next.isFinal))
            }
        }
        worker = nil
    }

    private func decode(_ job: Job) async -> String {
        let request = WhisperRunRequest(samples: PCMAudio.floats(job.samples), offsetSeconds: 0, language: language,
                                        prompt: prompt, mode: .live, scripts: ScriptRestriction(language: language))
        let tokens = Mutex<[TimedToken]>([])
        do {
            _ = try await core.run(request, onSegment: { _, t in tokens.withLock { $0.append(contentsOf: t) } },
                                   onProgress: { _ in }, shouldAbort: { false })
        } catch {
            let kind = job.isFinal ? "final" : "partial"
            Self.logger.error("live decode failed (\(kind, privacy: .public) window \(job.from, privacy: .public)–\(job.to, privacy: .public) s): \(String(describing: error), privacy: .public)")
            return ""
        }
        let text = OverlapTrimmer.text(tokens.withLock { $0 }, droppingBefore: job.dropBefore)
        return RepetitionFilter.clean([WhisperSegment(start: 0, end: 0, text: text)]).first?.text ?? ""
    }

    private func sampleIndex(_ seconds: Double) -> Int { Int((seconds * PCMAudio.sampleRate).rounded()) }
}
