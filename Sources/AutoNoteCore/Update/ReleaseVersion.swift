import Foundation

/// A release version such as `0.6.0` (a tag may carry a leading `v`). Compared as numbers, part by part, with missing
/// parts read as 0 (`0.6` == `0.6.0`). Anything but dot-separated digits (`0.7.0-beta`, `latest`) is not a version:
/// the updater only follows plain releases.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else {
                return nil
            }
            numbers.append(n)
        }
        components = numbers
    }

    /// `0.6.0` (no `v`).
    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
