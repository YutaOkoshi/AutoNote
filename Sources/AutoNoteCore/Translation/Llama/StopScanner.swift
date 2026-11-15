import Foundation

/// Collects the bytes a completion generates and stops at the first stop string.
///
/// Works on UTF-8 bytes, not on `String`, because a token can end in the middle of a multi-byte character; the text is
/// decoded once at the end (`text`). Stop strings are matched across token boundaries.
struct StopScanner: Sendable {
    private let stops: [[UInt8]]
    private let longestStop: Int
    private(set) var bytes: [UInt8] = []
    /// True once a stop string was found; `bytes` then ends right before it.
    private(set) var stopped = false

    init(stops: [String]) {
        self.stops = stops.map { Array($0.utf8) }.filter { !$0.isEmpty }
        longestStop = self.stops.map(\.count).max() ?? 0
    }

    /// Appends one generated piece. Returns true when the text now contains a stop string (the stop string and anything
    /// after it are dropped). Does nothing after a stop.
    @discardableResult
    mutating func append<C: Collection>(_ piece: C) -> Bool where C.Element == UInt8 {
        guard !stopped else { return true }
        let before = bytes.count
        bytes.append(contentsOf: piece)
        guard longestStop > 0 else { return false }
        // A match can start up to `longestStop - 1` bytes before the new piece.
        let searchStart = max(0, before - (longestStop - 1))
        var earliest: Int?
        for stop in stops {
            if let at = Self.firstIndex(of: stop, in: bytes, from: searchStart), at < (earliest ?? .max) {
                earliest = at
            }
        }
        guard let earliest else { return false }
        bytes.removeSubrange(earliest...)
        stopped = true
        return true
    }

    /// The generated text so far. A multi-byte character cut off at the end (e.g. by `maxTokens`) is left out.
    var text: String {
        String(decoding: bytes[..<Self.completeUTF8Prefix(bytes)], as: UTF8.self)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count - start else { return nil }
        var i = start
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// The length of `bytes` without a trailing, incomplete UTF-8 sequence.
    static func completeUTF8Prefix(_ bytes: [UInt8]) -> Int {
        var i = bytes.count - 1
        var continuation = 0
        // Walk back over at most 3 continuation bytes (10xxxxxx) to the lead byte.
        while i >= 0, continuation < 3, bytes[i] & 0xC0 == 0x80 {
            continuation += 1
            i -= 1
        }
        guard i >= 0 else { return bytes.count }
        let lead = bytes[i]
        let expected: Int
        switch lead {
        case 0x00...0x7F: expected = 1
        case 0xC0...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF7: expected = 4
        default: return bytes.count   // not a valid lead byte; leave it to the decoder's replacement character
        }
        return continuation + 1 < expected ? i : bytes.count
    }
}
