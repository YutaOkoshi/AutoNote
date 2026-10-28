import Foundation
import os
import Synchronization

/// Final (batch) transcription with whisper, one window at a time (`BatchWindowPlanner`) so only one window's
/// samples are in memory. Pausing aborts whisper at the next segment boundary and restarts the window from the end of
/// its last completed segment after `resume()`; the gate is also waited on before every window. Segment times are
/// shifted by the window's start and each segment is kept by the window that owns its midpoint. Utterances come back
/// with `speaker: .unknown` and times relative to the file (Task 11 assigns speaker and start offset).
/// A segment over audio with less than `SilenceDetector`'s minimum speech is dropped (whisper hallucinates on silence).
/// The file must be a 16 kHz mono 16-bit WAV (`TranscriptionError.invalidAudio` otherwise).
public actor WhisperBatchTranscriber: BatchTranscriber {
    /// Writes to the unified log (subsystem `com.yutaokoshi.autonote`, category `WhisperBatchTranscriber`).
    public static let systemLog: @Sendable (String) -> Void = { message in
        logger.info("\(message, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "WhisperBatchTranscriber")

    private let core: any WhisperCore
    private let gate: BatchGate
    private let windows: BatchWindowPlanner.Config
    private let log: @Sendable (String) -> Void

    public init(core: any WhisperCore, gate: BatchGate, windows: BatchWindowPlanner.Config = .init(),
                log: @escaping @Sendable (String) -> Void = WhisperBatchTranscriber.systemLog) {
        self.core = core
        self.gate = gate
        self.windows = windows
        self.log = log
    }

    public func transcribe(
        file: URL, language: Language, hints: [String], progress: @Sendable @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        guard let info = try? WAVFile.info(file), info.sampleRate == 16_000, info.channels == 1, info.bitsPerSample == 16
        else { throw TranscriptionError.invalidAudio("\(file.lastPathComponent): not a 16 kHz mono 16-bit WAV") }
        let count = try WAVFile.sampleCount(file)
        let plan = try BatchWindowPlanner(config: windows).plan(sampleCount: count) { try WAVFile.readSamples(file, in: $0) }
        let prompt = WhisperPrompt.make(hints: hints)
        let reported = Locked(0.0)
        let report: @Sendable (Double) -> Void = { value in
            let clamped = min(1, max(0, value))
            let forward = reported.withLock { last -> Bool in
                guard clamped > last else { return false }
                last = clamped
                return true
            }
            if forward { progress(clamped) }
        }
        let detector = SilenceDetector()
        var collected: [WhisperSegment] = []

        for w in plan {
            try Task.checkCancellation()
            let pcm = try WAVFile.readSamples(file, in: w.read)
            let samples = PCMAudio.floats(pcm)
            let kept = try await decode(samples, language: language, prompt: prompt) { p in
                guard count > 0 else { return }
                report((Double(w.owned.lowerBound) + p * Double(w.owned.count)) / Double(count))
            }
            let shift = Double(w.read.lowerBound) / PCMAudio.sampleRate
            for s in kept where detector.hasSpeech(in: pcm, from: s.start, to: s.end)
                && w.owns(midpointSeconds: shift + (s.start + s.end) / 2) {
                collected.append(WhisperSegment(start: s.start + shift, end: s.end + shift, text: s.text))
            }
            log("文字起こし 窓 \(w.index + 1)/\(plan.count)（\(Self.minutes(w.owned.upperBound)) 分 / \(Self.minutes(count)) 分）")
        }
        report(1.0)
        return RepetitionFilter.clean(collected).map {
            Utterance(start: TimelineTime(seconds: $0.start), end: TimelineTime(seconds: $0.end),
                      speaker: .unknown, text: $0.text, isFinal: true)
        }
    }

    /// Runs whisper over one window, restarting after each pause from the end of the last completed segment.
    /// Returns the window's segments (times from the start of `samples`); `progress` gets 0...1 through the window.
    private func decode(
        _ samples: [Float], language: Language, prompt: String?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperSegment] {
        let total = Double(samples.count) / PCMAudio.sampleRate
        let kept = Locked<[WhisperSegment]>([])
        let cancelled = Locked(false)
        let gate = self.gate
        var offset = 0.0

        while true {
            try Task.checkCancellation()
            await gate.waitIfPaused()
            try Task.checkCancellation()
            let stop = Locked(false)
            let start = offset
            let request = WhisperRunRequest(samples: samples, offsetSeconds: start, language: language, prompt: prompt, mode: .batch)
            let outcome = try await withTaskCancellationHandler {
                try await core.run(
                    request,
                    onSegment: { segment, _ in
                        kept.withLock { $0.append(segment) }
                        if gate.isPaused { stop.withLock { $0 = true } }   // セグメント境界で一時停止を見る
                    },
                    onProgress: { p in
                        guard total > 0 else { return }
                        progress((start + p * (total - start)) / total)
                    },
                    shouldAbort: { cancelled.withLock { $0 } || stop.withLock { $0 } })
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
            if outcome == .completed { break }
            if Task.isCancelled { throw CancellationError() }
            offset = kept.withLock { $0.last?.end } ?? offset   // 最後に完了したセグメントの終わりから再開
        }
        return kept.withLock { $0 }
    }

    /// Samples as whole minutes, rounded.
    private static func minutes(_ samples: Int) -> Int { Int((Double(samples) / PCMAudio.sampleRate / 60).rounded()) }
}

/// A `Mutex` that closures can share by reference.
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout sending Value) throws -> sending R) rethrows -> R { try mutex.withLock(body) }
}
