import Foundation
import Synchronization

/// Per-track health of one recording, written to `manifest.audio_health` at stop. Tells apart "callbacks stopped"
/// (`noCallbackSeconds`) from "callbacks kept coming with all-zero samples" (`zeroSeconds`).
public struct TrackHealth: Codable, Equatable, Hashable, Sendable {
    public var track: Track
    /// Whole seconds of the meeting timeline (0 ..< recorded length) in which no callback delivered any frame.
    public var noCallbackSeconds: Int
    /// Whole seconds that received callbacks, all of whose samples were exactly zero.
    public var zeroSeconds: Int
    /// Times the source rebuilt its input after the hardware configuration changed or the input stalled.
    public var restarts: Int
    public var callbacks: Int

    public init(track: Track, noCallbackSeconds: Int, zeroSeconds: Int, restarts: Int, callbacks: Int) {
        self.track = track; self.noCallbackSeconds = noCallbackSeconds; self.zeroSeconds = zeroSeconds
        self.restarts = restarts; self.callbacks = callbacks
    }
}

/// A source stopped delivering audio after a successful start (reported through `SourceHealth`).
public struct SourceRuntimeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// Counters a source shares with its owner: written by the drain task (one record = one callback) and the source,
/// read by `RecordingSession` at stop. Not on the real-time thread. One instance per source.
public final class SourceHealth: Sendable {
    /// Per whole timeline second: bit 0 = a callback delivered frames, bit 1 = some sample was non-zero.
    private struct State {
        var seconds: [UInt8] = []
        var callbacks = 0
        var restarts = 0
        var windowCallbacks = 0
        var windowNonZero = false
        var failureObserver: (@Sendable (String) -> Void)?
        var failure: String?
    }

    private static let maxSeconds = 24 * 3600   // bounds memory for a runaway timestamp
    private let state = Mutex(State())

    public init() {}

    /// One callback's worth of frames starting at `start` (timeline seconds) and lasting `duration` seconds.
    public func recordCallback(start: Double, duration: Double, nonZero: Bool) {
        state.withLock { s in
            s.callbacks += 1
            s.windowCallbacks += 1
            if nonZero { s.windowNonZero = true }
            guard start.isFinite, duration.isFinite, start + duration > 0 else { return }
            let first = max(0, Int(start.rounded(.down)))
            // A record ending exactly on a second boundary does not touch the next second.
            let last = min(Self.maxSeconds - 1, max(first, Int((start + max(duration, 0)).rounded(.up)) - 1))
            guard first <= last else { return }
            if s.seconds.count <= last { s.seconds.append(contentsOf: repeatElement(0, count: last + 1 - s.seconds.count)) }
            for i in first...last { s.seconds[i] |= nonZero ? 0b11 : 0b01 }
        }
    }

    public func noteRestart() { state.withLock { $0.restarts += 1 } }

    public var restarts: Int { state.withLock { $0.restarts } }
    public var callbacks: Int { state.withLock { $0.callbacks } }

    /// Callbacks since the previous call and whether any of them held a non-zero sample; resets the window.
    public func takeWindow() -> (callbacks: Int, nonZero: Bool) {
        state.withLock { s in
            defer { s.windowCallbacks = 0; s.windowNonZero = false }
            return (s.windowCallbacks, s.windowNonZero)
        }
    }

    /// Called once with a message when the source gives up delivering audio while it is still "running".
    public func setFailureObserver(_ observer: (@Sendable (String) -> Void)?) {
        let pending = state.withLock { s -> String? in s.failureObserver = observer; return s.failure }
        if let pending, let observer { observer(pending) }
    }

    func reportFailure(_ message: String) {
        let observer = state.withLock { s -> (@Sendable (String) -> Void)? in
            guard s.failure == nil else { return nil }
            s.failure = message
            return s.failureObserver
        }
        observer?(message)
    }

    /// The per-second marks, for merging several sources of one track (a microphone re-attached mid-meeting).
    fileprivate var marks: [UInt8] { state.withLock { $0.seconds } }

    /// Summary over `0 ..< ceil(endSeconds)` of every source the track had, in any order.
    public static func summary(track: Track, sources: [SourceHealth], endSeconds: Double) -> TrackHealth {
        let total = max(0, min(maxSeconds, Int(endSeconds.rounded(.up))))
        var merged = [UInt8](repeating: 0, count: total)
        var restarts = 0, callbacks = 0
        for source in sources {
            let marks = source.marks
            for i in 0..<min(total, marks.count) { merged[i] |= marks[i] }
            restarts += source.restarts
            callbacks += source.callbacks
        }
        let noCallback = merged.lazy.filter { $0 & 0b01 == 0 }.count
        let zero = merged.lazy.filter { $0 == 0b01 }.count
        return TrackHealth(track: track, noCallbackSeconds: noCallback, zeroSeconds: zero, restarts: restarts, callbacks: callbacks)
    }
}
