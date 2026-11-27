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
    /// Frames the ring buffers refused because the drain fell behind (`AudioRingBuffer.droppedFrames`), all rebuilds
    /// together. nil on recordings made before this field.
    public var droppedFrames: Int?
    /// System track: whole seconds in which another process was playing audio while every sample that arrived was
    /// exactly zero. A tap that went deaf looks like this; so does an app that keeps its output open and plays digital
    /// silence. nil when the source does not watch other processes (the microphone, older recordings).
    public var suspectZeroSeconds: Int?
    /// System track: whole seconds in which another process was playing audio while no callback arrived. (With nobody
    /// playing, an idle tap delivers no callbacks at all, so `noCallbackSeconds` alone says nothing.) nil as above.
    public var suspectNoCallbackSeconds: Int?
    /// Of `noCallbackSeconds`, those that lay inside a pause of the recording (nothing was being recorded then).
    /// nil when there were none.
    public var pausedNoCallbackSeconds: Int?

    public init(track: Track, noCallbackSeconds: Int, zeroSeconds: Int, restarts: Int, callbacks: Int,
                droppedFrames: Int? = nil, suspectZeroSeconds: Int? = nil, suspectNoCallbackSeconds: Int? = nil,
                pausedNoCallbackSeconds: Int? = nil) {
        self.track = track; self.noCallbackSeconds = noCallbackSeconds; self.zeroSeconds = zeroSeconds
        self.restarts = restarts; self.callbacks = callbacks
        self.droppedFrames = droppedFrames; self.suspectZeroSeconds = suspectZeroSeconds
        self.suspectNoCallbackSeconds = suspectNoCallbackSeconds
        self.pausedNoCallbackSeconds = pausedNoCallbackSeconds
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
    /// Per whole timeline second: bit 0 = a callback delivered frames, bit 1 = some sample was non-zero,
    /// bit 2 = a poll saw another process playing audio, bit 3 = a poll saw nobody playing.
    private struct State {
        var seconds: [UInt8] = []
        var callbacks = 0
        var nonZeroCallbacks = 0
        var windowState = WindowState.normal
        var restarts = 0
        var droppedFrames = 0
        var polled = false
        var paused = false
        var windowCallbacks = 0
        var windowNonZero = false
        var failureObserver: (@Sendable (String) -> Void)?
        var failure: String?
        var notArrivingObserver: (@Sendable (Int) -> Void)?
        var notArriving: Int?
    }

    private static let delivered: UInt8 = 0b0001, nonZero: UInt8 = 0b0010
    private static let othersPlaying: UInt8 = 0b0100, nobodyPlaying: UInt8 = 0b1000

    private static let maxSeconds = 24 * 3600   // bounds memory for a runaway timestamp
    private let state = Mutex(State())

    public init() {}

    /// One callback's worth of frames starting at `start` (timeline seconds) and lasting `duration` seconds.
    public func recordCallback(start: Double, duration: Double, nonZero: Bool) {
        state.withLock { s in
            s.callbacks += 1
            s.windowCallbacks += 1
            if nonZero { s.windowNonZero = true; s.nonZeroCallbacks += 1 }
            guard start.isFinite, duration.isFinite, start + duration > 0 else { return }
            let first = max(0, Int(start.rounded(.down)))
            // A record ending exactly on a second boundary does not touch the next second.
            let last = min(Self.maxSeconds - 1, max(first, Int((start + max(duration, 0)).rounded(.up)) - 1))
            guard first <= last else { return }
            if s.seconds.count <= last { s.seconds.append(contentsOf: repeatElement(0, count: last + 1 - s.seconds.count)) }
            for i in first...last { s.seconds[i] |= nonZero ? 0b11 : 0b01 }
        }
    }

    /// One look at "is a process other than this app playing audio" at `seconds` on the timeline (the system source's
    /// watchdog asks a few times a second). A second counts as suspect only when every poll in it said yes.
    public func recordOutputPoll(at seconds: Double, othersPlaying: Bool) {
        state.withLock { s in
            s.polled = true
            guard seconds.isFinite, seconds >= 0 else { return }
            let i = min(Self.maxSeconds - 1, Int(seconds.rounded(.down)))
            if s.seconds.count <= i { s.seconds.append(contentsOf: repeatElement(0, count: i + 1 - s.seconds.count)) }
            s.seconds[i] |= othersPlaying ? Self.othersPlaying : Self.nobodyPlaying
        }
    }

    public func noteRestart() { state.withLock { $0.restarts += 1 } }

    /// Set by the recording while it is paused: the source goes on delivering, but nothing is written, so it does
    /// not rebuild for zeros or report audio as not arriving meanwhile.
    public func setPaused(_ paused: Bool) { state.withLock { $0.paused = paused } }
    public var isPaused: Bool { state.withLock { $0.paused } }

    /// Frames a retired ring buffer had dropped (called when a rebuild or the stop lets go of the ring).
    public func addDroppedFrames(_ frames: Int) { state.withLock { $0.droppedFrames += max(0, frames) } }

    public var restarts: Int { state.withLock { $0.restarts } }
    public var callbacks: Int { state.withLock { $0.callbacks } }
    /// Callbacks so far that held a non-zero sample: a watchdog compares two readings to learn whether audio still arrives.
    public var nonZeroCallbacks: Int { state.withLock { $0.nonZeroCallbacks } }

    /// What a track delivered in one log window.
    public enum WindowState: String, Sendable {
        case normal
        case allZero = "all_zero"
        case noCallbacks = "no_callbacks"
    }

    /// Callbacks since the previous call, the state of that window, and the state before it when the two differ (a
    /// track starts out `normal`); resets the window. Kept here, not in the drain, so it carries across a rebuild's
    /// new drain.
    public func closeWindow() -> (callbacks: Int, state: WindowState, changedFrom: WindowState?) {
        state.withLock { s in
            defer { s.windowCallbacks = 0; s.windowNonZero = false }
            let now: WindowState = s.windowCallbacks == 0 ? .noCallbacks : (s.windowNonZero ? .normal : .allZero)
            let before = s.windowState
            s.windowState = now
            return (s.windowCallbacks, now, now == before ? nil : before)
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

    /// Called once with the seconds so far when the source keeps running but, for a long stretch, received nothing
    /// while another process was playing audio (and rebuilding did not help). Not a failure: the source goes on.
    public func setNotArrivingObserver(_ observer: (@Sendable (Int) -> Void)?) {
        let pending = state.withLock { s -> Int? in s.notArrivingObserver = observer; return s.notArriving }
        if let pending, let observer { observer(pending) }
    }

    func reportNotArriving(seconds: Int) {
        let observer = state.withLock { s -> (@Sendable (Int) -> Void)? in
            guard s.notArriving == nil else { return nil }
            s.notArriving = seconds
            return s.notArrivingObserver
        }
        observer?(seconds)
    }

    /// The per-second marks, for merging several sources of one track (a microphone re-attached mid-meeting).
    fileprivate var marks: [UInt8] { state.withLock { $0.seconds } }
    fileprivate var totals: (dropped: Int, polled: Bool) { state.withLock { ($0.droppedFrames, $0.polled) } }

    /// Summary over `0 ..< ceil(endSeconds)` of every source the track had, in any order.
    public static func summary(track: Track, sources: [SourceHealth], endSeconds: Double,
                               pauses: [PauseInterval] = []) -> TrackHealth {
        let total = max(0, min(maxSeconds, Int(endSeconds.rounded(.up))))
        var merged = [UInt8](repeating: 0, count: total)
        var restarts = 0, callbacks = 0, dropped = 0, polled = false
        for source in sources {
            let marks = source.marks
            for i in 0..<min(total, marks.count) { merged[i] |= marks[i] }
            restarts += source.restarts
            callbacks += source.callbacks
            let totals = source.totals
            dropped += totals.dropped
            polled = polled || totals.polled
        }
        let audio = delivered | nonZero
        let noCallback = merged.lazy.filter { $0 & delivered == 0 }.count
        let zero = merged.lazy.filter { $0 & audio == delivered }.count
        // Seconds wholly inside a pause (an open pause runs to the end): nothing was being recorded then.
        var paused = [Bool](repeating: false, count: total)
        for pause in pauses {
            let from = max(0, Int(pause.start.seconds.rounded(.up)))
            let to = min(total, Int((pause.end?.seconds ?? Double(total)).rounded(.down)))
            if from < to { for i in from..<to { paused[i] = true } }
        }
        let pausedNoCallback = merged.indices.lazy.filter { paused[$0] && merged[$0] & delivered == 0 }.count
        // Suspect: every poll of the second saw another process playing, and still no non-zero sample arrived.
        let suspect = merged.indices.lazy.filter { !paused[$0] && merged[$0] & (othersPlaying | nobodyPlaying) == othersPlaying }
        return TrackHealth(track: track, noCallbackSeconds: noCallback, zeroSeconds: zero, restarts: restarts, callbacks: callbacks,
                           droppedFrames: dropped,
                           suspectZeroSeconds: polled ? suspect.filter { merged[$0] & audio == delivered }.count : nil,
                           suspectNoCallbackSeconds: polled ? suspect.filter { merged[$0] & delivered == 0 }.count : nil,
                           pausedNoCallbackSeconds: pausedNoCallback > 0 ? pausedNoCallback : nil)
    }
}
