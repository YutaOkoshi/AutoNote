import Foundation
import Darwin

/// Source of host time (`mach_absolute_time` ticks) and its conversion to seconds.
public protocol HostClock: Sendable {
    func hostTime() -> UInt64
    func seconds(fromHostTicks ticks: UInt64) -> Double
    func hostTicks(fromSeconds s: Double) -> UInt64
}

/// Real clock. The tick ratio comes from `mach_timebase_info` at runtime (1/1 on Intel, 125/3 on Apple Silicon).
public struct MachHostClock: HostClock {
    private let numer: UInt32
    private let denom: UInt32

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = info.numer == 0 ? 1 : info.numer
        denom = info.denom == 0 ? 1 : info.denom
    }

    public func hostTime() -> UInt64 { mach_absolute_time() }

    public func seconds(fromHostTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1_000_000_000
    }

    public func hostTicks(fromSeconds s: Double) -> UInt64 {
        guard s > 0 else { return 0 }
        return UInt64((s * 1_000_000_000 * Double(denom) / Double(numer)).rounded())
    }
}

/// Maps host time to the meeting timeline (seconds since `origin`).
public struct MeetingClock: Sendable {
    public let origin: UInt64
    private let host: any HostClock

    public init(origin: UInt64, host: any HostClock) {
        self.origin = origin; self.host = host
    }

    /// Host times before `origin` give negative seconds.
    public func timeline(hostTime: UInt64) -> TimelineTime {
        if hostTime >= origin {
            return TimelineTime(seconds: host.seconds(fromHostTicks: hostTime - origin))
        }
        return TimelineTime(seconds: -host.seconds(fromHostTicks: origin - hostTime))
    }

    public func now() -> TimelineTime { timeline(hostTime: host.hostTime()) }
}
