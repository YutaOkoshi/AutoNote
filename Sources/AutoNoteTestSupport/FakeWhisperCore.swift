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
public final class FakeWhisperCore: WhisperCore, @unchecked Sendable {
    private enum Script {
        case segments([WhisperSegment], delay: Duration)
        case windows([[WhisperSegment]], delay: Duration)
        case fixedText(String)
        case failure(any Error)
    }

    private struct State {
        var requests: [WhisperRunRequest] = []
        var emitted = 0
        var window = -1
    }

    private let script: Script
    private let state = Mutex(State())

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
