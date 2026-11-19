import Foundation
import CoreAudio
import Synchronization
import AutoNoteCore

/// Records `hold`/`release` and reports `steady` as set by the test.
public final class FakeMicrophoneInputHold: MicrophoneInputHolding, Sendable {
    private struct State {
        var holds = 0
        var releases = 0
        var held = false
        var steady = true
        var holdsBluetooth = true
        var steadyAt: ContinuousClock.Instant?
        var current = true
    }

    private let state = Mutex(State())

    public init(steady: Bool = true) { state.withLock { $0.steady = steady } }

    public var holdCount: Int { state.withLock { $0.holds } }
    public var releaseCount: Int { state.withLock { $0.releases } }
    public var isHeld: Bool { state.withLock { $0.held } }
    /// Whether `hold` reports a Bluetooth input (true) or declines (false, as for a built-in microphone).
    public var holdsBluetooth: Bool {
        get { state.withLock { $0.holdsBluetooth } }
        set { state.withLock { $0.holdsBluetooth = newValue } }
    }
    /// What `isSteady` answers; the moment it was last set to true is kept in `steadyAt`.
    public var steady: Bool {
        get { state.withLock { $0.steady } }
        set { state.withLock { $0.steady = newValue; if newValue { $0.steadyAt = .now } } }
    }
    public var steadyAt: ContinuousClock.Instant? { state.withLock { $0.steadyAt } }
    /// Whether the held device is still the one to hold (`isHolding`). Set false to play a new default input or a
    /// device that came back with a new ID; the next `hold` sets it true again.
    public var current: Bool {
        get { state.withLock { $0.current } }
        set { state.withLock { $0.current = newValue } }
    }

    public func isHolding(deviceID: AudioDeviceID?) -> Bool { state.withLock { $0.held && $0.current } }

    public func hold(deviceID: AudioDeviceID?) -> Bool {
        state.withLock { s in
            s.holds += 1
            if s.held { s.releases += 1 }   // `hold` releases what it held first
            s.held = s.holdsBluetooth
            s.current = true
            return s.holdsBluetooth
        }
    }

    public func isSteady(for duration: Duration) -> Bool { state.withLock { !$0.held || $0.steady } }

    public func release() {
        state.withLock { s in
            if s.held { s.releases += 1 }
            s.held = false
        }
    }
}
