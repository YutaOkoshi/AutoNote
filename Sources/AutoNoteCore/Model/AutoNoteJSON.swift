import Foundation

public enum AutoNoteJSON {
    /// Dates are written as ISO-8601 with milliseconds (`1970-01-01T00:00:00.000Z`) and read with or without the fraction.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatter(fractional: true).string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = formatter(fractional: true).date(from: s) ?? formatter(fractional: false).date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected an ISO-8601 date, got \(s)")
            }
            return date
        }
        return d
    }

    /// `ISO8601DateFormatter` is not `Sendable`; a fresh one per call keeps the strategies thread-safe.
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }
}
