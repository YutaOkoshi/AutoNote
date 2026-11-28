import AutoNoteCore
import Foundation
import Synchronization

/// Scripted `WhisperCore`. Each run emits, in order, the segments that start at or after the request's
/// `offsetSeconds` (waiting `delay` before each, without throwing on cancellation) and checks `shouldAbort` after every one.
/// `init(windows:delay:)` scripts a windowed batch: a call with `offsetSeconds == 0` starts the next window and plays
/// `windows[k]` (empty past the end; times from the start of the window), a resume call (`offsetSeconds > 0`) stays in
/// the current window.
/// `init(fixedText:)` is for live windows: one segment spanning the window and one token at its start.
/// `init(failure:)` records each request and throws `failure`.
/// `hold()` makes every `run` wait (after recording its request) until `release()`: a decoder slower than the audio,
/// without a clock.
/// `detectLanguage` answers with `guess` (Japanese by default), or throws `detectionError` when set, and records the
/// samples it was asked about.
public final class FakeWhisperCore: WhisperCore, @unchecked Sendable {
    private enum Script {
        case segments([WhisperSegment], delay: Duration)
        case windows([[WhisperSegment]], delay: Duration)
        case fixedText(String)
        case failure(any Error)
    }

    private struct State {
        var requests: [WhisperRunRequest] = []
        var detections: [[Float]] = []
        var emitted = 0
        var window = -1
    }

    private struct Gate {
        var closed = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let script: Script
    private let state = Mutex(State())
    private let gate = Mutex(Gate())

    /// From now on a `run` records its request and then waits for `release()`.
    public func hold() { gate.withLock { $0.closed = true } }

    /// Lets the waiting runs go on, and later ones through.
    public func release() {
        let waiting = gate.withLock { g -> [CheckedContinuation<Void, Never>] in
            g.closed = false
            defer { g.waiting = [] }
            return g.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    private func waitWhileHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = gate.withLock { g -> Bool in
                if g.closed { g.waiting.append(continuation) }
                return !g.closed
            }
            if open { continuation.resume() }
        }
    }

    /// The answer of `detectLanguage` for the samples asked about.
    public var guess: @Sendable ([Float]) -> LanguageGuess {
        get { guessBox.withLock { $0 } }
        set { guessBox.withLock { $0 = newValue } }
    }
    private let guessBox = Mutex<@Sendable ([Float]) -> LanguageGuess>({ _ in LanguageGuess(ja: 0.9, en: 0.1) })

    /// Thrown by `detectLanguage` when set (decoding still follows the script).
    public var detectionError: (any Error)? {
        get { errorBox.withLock { $0 } }
        set { errorBox.withLock { $0 = newValue } }
    }
    private let errorBox = Mutex<(any Error)?>(nil)

    public init(segments: [WhisperSegment], delay: Duration = .zero) {
        script = .segments(segments, delay: delay)
    }

    public init(windows: [[WhisperSegment]], delay: Duration = .zero) {
        script = .windows(windows, delay: delay)
    }

    public init(fixedText: String) {
        script = .fixedText(fixedText)
    }

    public init(failure: any Error) {
        script = .failure(failure)
    }

    public var requests: [WhisperRunRequest] { state.withLock { $0.requests } }
    public var runCount: Int { state.withLock { $0.requests.count } }
    public var emittedCount: Int { state.withLock { $0.emitted } }
    /// The samples of each `detectLanguage` call, in order.
    public var detections: [[Float]] { state.withLock { $0.detections } }

    public func detectLanguage(_ samples: [Float]) async throws -> LanguageGuess {
        state.withLock { $0.detections.append(samples) }
        if case let .failure(error) = script { throw error }
        if let detectionError { throw detectionError }
        return guess(samples)
    }

    public func run(
        _ r: WhisperRunRequest,
        onSegment: @Sendable @escaping (WhisperSegment, [TimedToken]) -> Void,
        onProgress: @Sendable @escaping (Double) -> Void,
        shouldAbort: @Sendable @escaping () -> Bool
    ) async throws -> WhisperRunOutcome {
        let window = state.withLock { s -> Int in
            s.requests.append(r)
            if r.offsetSeconds == 0 { s.window += 1 }
            return s.window
        }
        await waitWhileHeld()
        let total = Double(r.samples.count) / PCMAudio.sampleRate
        switch script {
        case let .failure(error):
            throw error
        case let .fixedText(text):
            let segment = WhisperSegment(start: r.offsetSeconds, end: max(r.offsetSeconds, total), text: text)
            emit(segment, [TimedToken(start: r.offsetSeconds, end: segment.end, text: text)], onSegment)
            onProgress(1)
            return shouldAbort() ? .aborted : .completed
        case let .segments(all, delay):
            return await play(all, delay: delay, r, total: total, onSegment, onProgress, shouldAbort)
        case let .windows(windows, delay):
            let all = windows.indices.contains(window) ? windows[window] : []
            return await play(all, delay: delay, r, total: total, onSegment, onProgress, shouldAbort)
        }
    }

    private func play(
        _ all: [WhisperSegment], delay: Duration, _ r: WhisperRunRequest, total: Double,
        _ onSegment: @Sendable @escaping (WhisperSegment, [TimedToken]) -> Void,
        _ onProgress: @Sendable @escaping (Double) -> Void,
        _ shouldAbort: @Sendable @escaping () -> Bool
    ) async -> WhisperRunOutcome {
        for segment in all where segment.start >= r.offsetSeconds {
            if delay > .zero { try? await Task.sleep(for: delay) }   // 取り消しでも投げない（中断は shouldAbort で伝わる）
            emit(segment, [], onSegment)
            let span = total - r.offsetSeconds
            onProgress(span > 0 ? min(1, max(0, (segment.end - r.offsetSeconds) / span)) : 1)
            if shouldAbort() { return .aborted }
        }
        onProgress(1)
        return .completed
    }

    private func emit(_ segment: WhisperSegment, _ tokens: [TimedToken], _ onSegment: (WhisperSegment, [TimedToken]) -> Void) {
        onSegment(segment, tokens)
        state.withLock { $0.emitted += 1 }   // onSegment の後に数える（一時停止のテストが頼る）
    }
}
