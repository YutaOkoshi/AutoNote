import Foundation

public struct MeetingID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// `yyyyMMdd-HHmm-<suffix>`, with the date fields taken in `timeZone`.
    public static func make(start: Date, timeZone: TimeZone = .current, suffix: String = MeetingID.randomSuffix()) -> MeetingID {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let stamp = String(format: "%04d%02d%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return MeetingID(rawValue: "\(stamp)-\(suffix)")
    }

    /// Four lowercase hex digits.
    public static func randomSuffix() -> String {
        String(format: "%04x", UInt16.random(in: .min ... .max))
    }
}
