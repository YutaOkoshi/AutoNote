import Foundation

public enum MeetingFileName {
    public static let maxTitleLength = 60

    private static let replacements: [Character: String] = [
        "/": "／", "\\": "＼", ":": "：", "*": "＊", "?": "？", "\"": "”", "<": "＜", ">": "＞",
        "|": "｜", "#": "＃", "^": "＾", "[": "［", "]": "］",
    ]

    public static func titled(start: Date, title: String, timeZone: TimeZone) -> String {
        "\(format(start, "yyyy-MM-dd_HHmm", timeZone))_\(sanitize(title)).md"
    }

    public static func untitled(start: Date, timeZone: TimeZone) -> String {
        "\(format(start, "yyyy-MM-dd_HHmmss", timeZone)).md"
    }

    public static func yearFolder(start: Date, timeZone: TimeZone) -> String {
        format(start, "yyyy", timeZone)
    }

    public static func sanitize(_ title: String) -> String {
        var mapped = ""
        for ch in title {
            if let r = replacements[ch] {
                mapped += r
            } else if ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) {
                mapped += " "
            } else {
                mapped.append(ch)
            }
        }
        let collapsed = mapped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        var result = trimmed(collapsed)
        if result.count > maxTitleLength { result = trimmed(String(result.prefix(maxTitleLength))) }
        return result.isEmpty ? "無題" : result
    }

    public static func isUntitled(_ fileName: String) -> Bool {
        fileName.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{6}(-\d+)?\.md/) != nil
    }

    public static func unique(_ fileName: String, exists: (String) -> Bool) -> String {
        guard exists(fileName) else { return fileName }
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    private static func trimmed(_ s: String) -> String {
        var chars = Substring(s)
        while let f = chars.first, f == " " || f == "." { chars.removeFirst() }
        while let l = chars.last, l == " " || l == "." { chars.removeLast() }
        return String(chars)
    }

    static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
