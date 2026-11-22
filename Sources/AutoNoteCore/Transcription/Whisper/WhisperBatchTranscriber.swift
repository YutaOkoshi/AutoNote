import Foundation
import os
import Synchronization

/// Final (batch) transcription with whisper, one window at a time (`BatchWindowPlanner`) so only one window's
/// samples are in memory. Pausing aborts whisper at the next segment boundary and restarts the window from the end of
/// its last completed segment after `resume()`; the gate is also waited on before every window. Segment times are
/// shifted by the window's start and each segment is kept by the window that owns its midpoint. Utterances come back
/// with `speaker: .unknown` and times relative to the file (the caller assigns speaker and start offset).
/// A segment over audio with less than `SilenceDetector`'s minimum speech is dropped (whisper hallucinates on silence).
/// The file must be a 16 kHz mono 16-bit WAV (`TranscriptionError.invalidAudio` otherwise).
/// With `.auto` and `.perBlock` splitting, each window is split into runs of Japanese or English (`LanguageRunPlanner`)
/// and each run is decoded on its own with its language fixed; a window in one language is a single run, the same call
/// as a fixed language. A window with no block to judge is judged once from where its speech starts, and a window with
/// nothing decisive keeps the language the window before ended in. A failed judgement counts as none (logged).
/// With `.perWindow` splitting, whisper judges Japanese or English once per window (`WhisperContext`).
public actor WhisperBatchTranscriber: BatchTranscriber {
    /// Writes to the unified log (subsystem `com.yutaokoshi.autonote`, category `WhisperBatchTranscriber`).
    public static let systemLog: @Sendable (String) -> Void = { message in
        logger.info("\(message, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "WhisperBatchTranscriber")

    private let core: any WhisperCore
    private let gate: BatchGate
    private let windows: BatchWindowPlanner.Config
    private let languages: LanguageRunPlanner
    private let splitting: AutoLanguageSplitting
    private let log: @Sendable (String) -> Void

    /// The share of a window's progress that the language judgements take with `.auto` per block (the rest is decoding).
    public static let judgingShare = 0.1

    public init(core: any WhisperCore, gate: BatchGate, windows: BatchWindowPlanner.Config = .init(),
                languages: LanguageRunPlanner.Config = .init(), splitting: AutoLanguageSplitting = .perBlock,
                log: @escaping @Sendable (String) -> Void = WhisperBatchTranscriber.systemLog) {
        self.core = core
        self.gate = gate
        self.windows = windows
        self.languages = LanguageRunPlanner(config: languages)
        self.splitting = splitting
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
        let perBlock = language == .auto && splitting == .perBlock
        let judging = perBlock ? Self.judgingShare : 0
        var collected: [WhisperSegment] = []
        var previous: Language?   // the language the last judged window ended in

        for w in plan {
            try Task.checkCancellation()
            let pcm = try WAVFile.readSamples(file, in: w.read)
            let windowProgress: @Sendable (Double) -> Void = { inWindow in
                guard count > 0 else { return }
                report((Double(w.owned.lowerBound) + inWindow * Double(w.owned.count)) / Double(count))
            }
            let runs: [LanguageRunPlanner.Run]
            if perBlock {
                let judged = try await languageRuns(pcm, previous: previous) { windowProgress(judging * $0) }
                runs = judged.runs
                if judged.judged { previous = runs.last?.language }
            } else {
                runs = [LanguageRunPlanner.Run(samples: 0..<pcm.count, language: language)]
            }
            if language == .auto {
                log("言語 窓 \(w.index + 1)/\(plan.count): " + runs.map {
                    "\($0.language.rawValue) \(Self.seconds(w.read.lowerBound + $0.samples.lowerBound))–\(Self.seconds(w.read.lowerBound + $0.samples.upperBound)) 秒"
                }.joined(separator: "、"))
            }
            for run in runs {
                let samples = PCMAudio.floats(run.samples == pcm.indices ? pcm : Array(pcm[run.samples]))
                let kept = try await decode(samples, language: run.language, prompt: prompt) { p in
                    guard !pcm.isEmpty else { return }
                    let decoded = (Double(run.samples.lowerBound) + p * Double(run.samples.count)) / Double(pcm.count)
                    windowProgress(judging + (1 - judging) * decoded)
                }
                let inRun = Double(run.samples.lowerBound) / PCMAudio.sampleRate
                let runSeconds = Double(run.samples.count) / PCMAudio.sampleRate
                let shift = Double(w.read.lowerBound) / PCMAudio.sampleRate + inRun
                for s in kept {
                    // 自動では、区間の外（次の区間の発話）を見て無音の幻が残らないよう、無音判定を区間の中に切り詰める
                    var end = s.end
                    if language == .auto {
                        guard s.start < runSeconds else { continue }
                        end = min(s.end, runSeconds)
                    }
                    guard detector.hasSpeech(in: pcm, from: s.start + inRun, to: end + inRun),
                          w.owns(midpointSeconds: shift + (s.start + s.end) / 2) else { continue }
                    collected.append(WhisperSegment(start: s.start + shift, end: s.end + shift, text: s.text))
                }
            }
            log("文字起こし 窓 \(w.index + 1)/\(plan.count)（\(Self.minutes(w.owned.upperBound)) 分 / \(Self.minutes(count)) 分）")
        }
        report(1.0)
        return RepetitionFilter.clean(collected).map {
            Utterance(start: TimelineTime(seconds: $0.start), end: TimelineTime(seconds: $0.end),
                      speaker: .unknown, text: $0.text, isFinal: true)
        }
    }

    /// The window's runs of Japanese and English: whisper judges each block with enough speech (waiting on the gate
    /// before each, like before every decode); with none, the window once from where its speech starts. `judged` is
    /// whether any judgement came back. `progress` gets 0...1 through the blocks.
    private func languageRuns(
        _ pcm: [Int16], previous: Language?, progress: @Sendable (Double) -> Void
    ) async throws -> (runs: [LanguageRunPlanner.Run], judged: Bool) {
        let blocks = languages.blocks(pcm)
        var guesses: [LanguageGuess?] = []
        for block in blocks {
            guesses.append(languages.shouldJudge(pcm, block) ? try await judge(Array(pcm[block])) : nil)
            if !pcm.isEmpty { progress(Double(block.upperBound) / Double(pcm.count)) }
        }
        if !guesses.isEmpty, guesses.allSatisfy({ $0 == nil }), let start = languages.speechStart(pcm) {
            guesses[0] = try await judge(Array(pcm[start...]))   // 判定できる塊が無い窓（短い発話だけ）は窓を 1 回判定する
        }
        let runs = languages.runs(blocks, guesses: guesses, previous: previous)
        let judged = guesses.contains { $0 != nil }
        return (runs.isEmpty ? [LanguageRunPlanner.Run(samples: 0..<pcm.count, language: previous ?? .ja)] : runs, judged)   // 空の窓も 1 回回す
    }

    /// whisper's guess for `pcm`, or nil when it fails (logged; the block then keeps the language before it).
    private func judge(_ pcm: [Int16]) async throws -> LanguageGuess? {
        try Task.checkCancellation()
        await gate.waitIfPaused()
        try Task.checkCancellation()
        do {
            return try await core.detectLanguage(PCMAudio.floats(pcm))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("言語の判定に失敗（直前の言語を使う）: \(error)")
            return nil
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

    /// Samples as whole seconds, rounded.
    private static func seconds(_ samples: Int) -> Int { Int((Double(samples) / PCMAudio.sampleRate).rounded()) }

    /// Samples as whole minutes, rounded.
    private static func minutes(_ samples: Int) -> Int { Int((Double(samples) / PCMAudio.sampleRate / 60).rounded()) }
}

/// A `Mutex` that closures can share by reference.
private final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout sending Value) throws -> sending R) rethrows -> R { try mutex.withLock(body) }
}
