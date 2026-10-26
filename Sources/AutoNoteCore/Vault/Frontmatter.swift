import Foundation

public enum Frontmatter {
    /// Top-level `key: value` pairs of a leading `---` block; nil when the document has none.
    /// Double-quoted values are unquoted (`\"` and `\\` restored), inverting `FrontmatterTemplate`.
    public static func parse(_ document: String) -> [String: String]? {
        let document = document.normalizingNewlines
        guard document.hasPrefix("---\n") else { return nil }
        var result: [String: String] = [:]
        for line in document.dropFirst(4).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == "---" && !line.hasPrefix(" ") { return result }
            guard let m = line.prefixMatch(of: /([A-Za-z0-9_]+):(.*)/) else { continue }
            result[String(m.output.1)] = unquote(String(m.output.2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func unquote(_ v: String) -> String {
        guard v.count >= 2, v.first == "\"", v.last == "\"" else { return v }
        var out = ""
        var escaped = false
        for ch in v.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false } else if ch == "\\" { escaped = true } else { out.append(ch) }
        }
        if escaped { out.append("\\") }
        return out
    }
}

extension String {
    /// `\r\n` and lone `\r` become `\n` (files saved by Windows editors or old Mac tools).
    var normalizingNewlines: String {
        replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
