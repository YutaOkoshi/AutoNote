import Foundation

public enum VaultScanner {
    public static func scan(outputFolder: URL) throws -> [IndexEntry] {
        try meetingFiles(in: outputFolder).map { entry(for: $0.url, frontmatter: $0.frontmatter, text: $0.text, base: $0.base) }
            .sorted { $0.linkPath < $1.linkPath }
    }

    /// Every meeting file whose `autonote_id` matches (several when the file was duplicated).
    public static func locate(_ id: MeetingID, in outputFolder: URL) throws -> [URL] {
        try meetingFiles(in: outputFolder).filter { $0.frontmatter["autonote_id"] == id.rawValue }.map(\.url)
            .sorted { $0.path < $1.path }
    }

    private struct Found { let url: URL; let frontmatter: [String: String]; let text: String; let base: URL }

    private static func meetingFiles(in outputFolder: URL) throws -> [Found] {
        let base = outputFolder.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var found: [Found] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                if name == "_autonote" || name.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension == "md", name != "_index.md", !name.hasPrefix("."),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let fm = Frontmatter.parse(text), fm["autonote_id"] != nil else { continue }
            found.append(Found(url: url, frontmatter: fm, text: text, base: base))
        }
        return found
    }

    private static func entry(for url: URL, frontmatter fm: [String: String], text: String, base: URL) -> IndexEntry {
        let status = fm["status"] ?? ""
        var firstLine = status == "transcript_only" ? "（議事録未生成）" : ""
        var inSummary = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "## 3行要約" { inSummary = true; continue }
            guard inSummary else { continue }
            if line.hasPrefix("## ") { break }
            if line.hasPrefix("- ") { firstLine = String(line.dropFirst(2)); break }
        }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var rel = url.resolvingSymlinksInPath().path
        if rel.hasPrefix(prefix) { rel.removeFirst(prefix.count) }
        if rel.hasSuffix(".md") { rel.removeLast(3) }
        return IndexEntry(meetingID: MeetingID(rawValue: fm["autonote_id"] ?? ""), date: fm["date"] ?? "", start: fm["start"] ?? "",
                          title: fm["title"] ?? "", durationMinutes: fm["duration_min"].flatMap { Int($0) },
                          firstLine: firstLine, status: status, linkPath: rel)
    }
}
