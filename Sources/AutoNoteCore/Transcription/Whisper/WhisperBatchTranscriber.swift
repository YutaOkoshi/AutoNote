import Foundation
import Synchronization

/// Final (batch) transcription with whisper. Pausing aborts whisper at the next segment boundary and
/// restarts from the end of the last completed segment after `resume()`. Utterances come back with
/// `speaker: .unknown` and times relative to the file (Task 11 assigns speaker and start offset).
/// A segment over audio with less than `SilenceDetector`'s minimum speech is dropped (whisper hallucinates on silence).
public actor WhisperBatchTranscriber: BatchTranscriber {
    private let core: any WhisperCore
    private let gate: BatchGate

    public init(core: any WhisperCore, gate: BatchGate) {
        self.core = core
        self.gate = gate
    }

    public func transcribe(
        file: URL, language: Language, hints: [String], progress: @Sendable @escaping (Double) -> Void
    ) async throws -> [Utterance] {
        let pcm = try PCMAudio.readMono16k(file)
        let samples = PCMAudio.floats(pcm)
        let total = Double(samples.count) / PCMAudio.sampleRate
        let prompt = WhisperPrompt.make(hints: hints)
        let kept = Locked<[WhisperSegment]>([])
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
                        report((start + p * (total - start)) / total)
                    },
                    shouldAbort: { cancelled.withLock { $0 } || stop.withLock { $0 } })
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
            if outcome == .completed { break }
            if Task.isCancelled { throw CancellationError() }
            offset = kept.withLock { $0.last?.end } ?? offset   // 最後に完了したセグメントの終わりから再開
        }
        report(1.0)
        let detector = SilenceDetector()
        let audible = kept.withLock { $0 }.filter { detector.hasSpeech(in: pcm, from: $0.start, to: $0.end) }
        return RepetitionFilter.clean(audible).map {
            Utterance(start: TimelineTime(seconds: $0.start), end: TimelineTime(seconds: $0.end),
                      speaker: .unknown, text: $0.text, isFinal: true)
        }
    }
}

/// A `Mutex` that closures can share by reference.
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout sending Value) throws -> sending R) rethrows -> R { try mutex.withLock(body) }
}
