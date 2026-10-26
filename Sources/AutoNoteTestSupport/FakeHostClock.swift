import Foundation
import AutoNoteCore

/// Manual clock, 1 tick = 1 ns, starting at 0.
public final class FakeHostClock: HostClock, @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: UInt64 = 0

    public init() {}

    public func advance(_ seconds: Double) {
        lock.withLock { ticks += hostTicks(fromSeconds: seconds) }
    }

    public func hostTime() -> UInt64 { lock.withLock { ticks } }
    public func hostTime(atSeconds s: Double) -> UInt64 { hostTicks(fromSeconds: s) }
    public func seconds(fromHostTicks ticks: UInt64) -> Double { Double(ticks) / 1_000_000_000 }
    public func hostTicks(fromSeconds s: Double) -> UInt64 { s > 0 ? UInt64((s * 1_000_000_000).rounded()) : 0 }
}

extension MeetingClock {
    public static func fake(_ host: FakeHostClock = FakeHostClock()) -> MeetingClock {
        MeetingClock(origin: 0, host: host)
    }
}
