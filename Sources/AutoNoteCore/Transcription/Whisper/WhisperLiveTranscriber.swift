import Foundation
import os
import Synchronization

/// Realtime transcription with whisper by re-decoding a sliding window (`ChunkPlanner`).
/// A window's partials and its final share one `start`, so consumers overwrite by `start` (overview §4).
/// One decode runs at a time: commits run in order and are never dropped; at most one partial waits,
/// a newer partial replacing the waiting one. A failed decode is logged and yields empty text
/// (an empty final still goes out so the consumer removes that window's partial).
public actor WhisperLiveTranscriber: LiveTranscriber {
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

    public init(core: any WhisperCore, config: ChunkPlanner.Config = .init()) {
        self.core = core
        planner = ChunkPlanner(config: config)
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
        mapper.append(chunk)
        buffer.append(contentsOf: chunk.samples)
        schedule(planner.ingest(chunk.samples))
    }

    /// Decodes what is left and ends the stream. Later (or concurrent) calls wait for the same ending.
    public func finish() async {
        if accepting {
            accepting = false
            schedule(planner.flush())
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
        if worker == nil, !jobs.isEmpty { worker = Task { await drain() } }
    }

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
            let text = await decode(next)
            if next.isFinal || !text.isEmpty {                      // 空の確定は部分結果ごと消すために流す
                continuation?.yield(Utterance(start: next.start, end: next.end, speaker: .unknown, text: text, isFinal: next.isFinal))
            }
        }
        worker = nil
    }

    private func decode(_ job: Job) async -> String {
        let request = WhisperRunRequest(samples: PCMAudio.floats(job.samples), offsetSeconds: 0, language: language,
                                        prompt: prompt, mode: .live)
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
