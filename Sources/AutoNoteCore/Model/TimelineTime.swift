import Foundation

/// Meeting timeline position in seconds since recording start (keeps advancing while paused).
public struct TimelineTime: Codable, Comparable, Hashable, Sendable {
    public var seconds: Double

    public init(seconds: Double) { self.seconds = seconds }

    public init(from decoder: any Decoder) throws {
        seconds = try decoder.singleValueContainer().decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(seconds)
    }

    public static let zero = TimelineTime(seconds: 0)

    /// Parses `HH:MM:SS` (hours may exceed two digits; minutes and seconds below 60).
    public init?(hhmmss: String) {
        let parts = hhmmss.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count >= 2, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
              m < 60, s < 60 else { return nil }
        self.init(seconds: Double(h * 3600 + m * 60 + s))
    }

    public static func < (lhs: TimelineTime, rhs: TimelineTime) -> Bool { lhs.seconds < rhs.seconds }
    public static func + (lhs: TimelineTime, rhs: TimelineTime) -> TimelineTime { TimelineTime(seconds: lhs.seconds + rhs.seconds) }

    private var parts: (h: Int, m: Int, s: Int) {
        let total = seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
        return (total / 3600, total % 3600 / 60, total % 60)
    }

    public var hhmmss: String { let p = parts; return String(format: "%02d:%02d:%02d", p.h, p.m, p.s) }
    public var anchor: String { let p = parts; return String(format: "t%02d-%02d-%02d", p.h, p.m, p.s) }
    public var mmss: String {
        let p = parts
        return p.h == 0 ? String(format: "%02d:%02d", p.m, p.s) : String(format: "%d:%02d:%02d", p.h, p.m, p.s)
    }
}
