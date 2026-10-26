import Foundation

public struct FrontmatterTemplate: Sendable {
    public static let requiredKeys = ["title", "date", "status", "autonote_id"]

    public static let defaultText = """
    title: {{title}}
    date: {{date}}
    start: "{{start}}"
    end: "{{end}}"
    duration_min: {{duration_min}}
    tags: [meeting]
    device: "{{device}}"
    transcript_engine: "{{transcript_engine}}"
    status: {{status}}
    autonote_id: {{autonote_id}}
    autonote: "{{autonote}}"
    """

    public let text: String

    public init(text: String) { self.text = text.normalizingNewlines }

    public func render(_ values: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let f = lines.first, f.trimmingCharacters(in: .whitespaces) == "---" { lines.removeFirst() }
        if let l = lines.last, l.trimmingCharacters(in: .whitespaces) == "---" { lines.removeLast() }

        var body = lines.map { Self.substitute($0, values) }
        var present = Set<String>()
        for line in body {
            if let m = line.prefixMatch(of: /([A-Za-z0-9_]+):/) { present.insert(String(m.output.1)) }
        }
        for key in Self.requiredKeys where !present.contains(key) {
            body.append("\(key): \(Self.yamlScalar(values[key] ?? ""))")
        }
        return "---\n" + body.joined(separator: "\n") + "\n---\n"
    }

    public static func values(manifest: Manifest, title: String, transcriptEngine: String, appVersion: String, timeZone: TimeZone) -> [String: String] {
        let device = manifest.source == .imported ? "import" : (manifest.device?.name ?? "")
        return [
            "title": title,
            "date": MeetingFileName.format(manifest.startedAt, "yyyy-MM-dd", timeZone),
            "start": MeetingFileName.format(manifest.startedAt, "HH:mm", timeZone),
            "end": manifest.endedAt.map { MeetingFileName.format($0, "HH:mm", timeZone) } ?? "",
            "duration_min": manifest.duration.map { String(Int(($0 / 60).rounded())) } ?? "",
            "device": device,
            "transcript_engine": transcriptEngine,
            "status": manifest.status.rawValue,
            "autonote_id": manifest.id.rawValue,
            "autonote": appVersion,
            "language": manifest.language.rawValue,
        ]
    }

    public static func yamlScalar(_ value: String) -> String {
        let v = singleLine(value)
        if needsQuoting(v) { return "\"" + escape(v) + "\"" }
        return v
    }

    private static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func needsQuoting(_ v: String) -> Bool {
        if v.isEmpty { return true }
        if v.first == " " || v.last == " " || v.first == "\t" || v.last == "\t" { return true }
        if let f = v.first, "-?:,[]{}#&*!|>'\"%@`".contains(f) { return true }
        if v.contains(": ") || v.contains(" #") { return true }
        return ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(v.lowercased())
    }

    /// Replaces `{{name}}`; inside a double-quoted span the value is escaped for that quote, outside it goes through `yamlScalar`.
    private static func substitute(_ line: String, _ values: [String: String]) -> String {
        var out = ""
        var inQuote = false
        var i = line.startIndex
        while i < line.endIndex {
            let rest = line[i...]
            if rest.hasPrefix("{{"), let m = rest.prefixMatch(of: /\{\{([A-Za-z0-9_]+)\}\}/) {
                let value = values[String(m.output.1)] ?? ""
                out += inQuote ? escape(singleLine(value)) : yamlScalar(value)
                i = m.range.upperBound
                continue
            }
            let ch = line[i]
            if ch == "\"" && !(out.last == "\\") { inQuote.toggle() }
            out.append(ch)
            i = line.index(after: i)
        }
        return out
    }
}
