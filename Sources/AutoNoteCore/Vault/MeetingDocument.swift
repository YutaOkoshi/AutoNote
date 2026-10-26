import Foundation

public struct MeetingDocument: Sendable {
    public let manifest: Manifest
    public let transcript: Transcript
    public let minutes: MinutesOutput?
    public let timeZone: TimeZone
    private let frontmatter: FrontmatterTemplate
    private let appVersion: String

    public init(manifest: Manifest, transcript: Transcript, minutes: MinutesOutput?,
                frontmatter: FrontmatterTemplate, appVersion: String, timeZone: TimeZone) {
        self.manifest = manifest; self.transcript = transcript; self.minutes = minutes
        self.frontmatter = frontmatter; self.appVersion = appVersion; self.timeZone = timeZone
    }

    private var givenTitle: String? {
        for candidate in [manifest.title, minutes?.title] {
            if let c = candidate, !TranscriptMarkdown.flatten(c).trimmingCharacters(in: .whitespaces).isEmpty { return c }
        }
        return nil
    }

    public var hasTitle: Bool { givenTitle != nil }

    public var title: String {
        givenTitle.map(TranscriptMarkdown.flatten)
            ?? "\(MeetingFileName.format(manifest.startedAt, "yyyy-MM-dd HH:mm", timeZone)) の会議"
    }

    public var preferredFileName: String {
        if manifest.status == .transcriptOnly || !hasTitle {
            return MeetingFileName.untitled(start: manifest.startedAt, timeZone: timeZone)
        }
        return MeetingFileName.titled(start: manifest.startedAt, title: title, timeZone: timeZone)
    }

    public var yearFolder: String { MeetingFileName.yearFolder(start: manifest.startedAt, timeZone: timeZone) }

    public static func link(_ time: TimelineTime, anchor: String?) -> String {
        guard let anchor else { return time.mmss }
        return "[[#^\(anchor)|\(time.mmss)]]"
    }

    public func render() -> String {
        let utterances = transcript.utterances
        let anchors = TranscriptMarkdown.anchors(for: utterances)
        func flat(_ s: String) -> String { TranscriptMarkdown.flatten(s) }
        func link(_ t: String) -> String? {
            guard let time = TimelineTime(hhmmss: t) else { return nil }
            return Self.link(time, anchor: TranscriptMarkdown.linkTarget(for: time, utterances: utterances, anchors: anchors))
        }
        func withLink(_ text: String, _ t: String) -> String {
            link(t).map { "\(flat(text)) \($0)" } ?? flat(text)
        }
        func cell(_ s: String?) -> String {
            guard let s, !flat(s).isEmpty else { return "—" }
            return flat(s).replacingOccurrences(of: "|", with: "\\|")
        }
        func list(_ items: [String]) -> String { items.isEmpty ? "- なし" : items.map { "- \($0)" }.joined(separator: "\n") }

        var sections: [String] = []
        let values = FrontmatterTemplate.values(manifest: manifest, title: title, transcriptEngine: transcript.engine,
                                                appVersion: appVersion, timeZone: timeZone)
        sections.append(String(frontmatter.render(values).dropLast()))
        sections.append("# \(title)")

        if let m = minutes {
            sections.append("## 3行要約\n" + list(m.summary.map(flat)))
            sections.append("## 決定事項\n" + list(m.decisions.map { withLink($0.text, $0.t) }))
            let agenda = m.agenda.enumerated().map { "### \($0.offset + 1). \(flat($0.element.title))\n\(withLink($0.element.body, $0.element.t))" }
            sections.append("## 議題\n" + (agenda.isEmpty ? "- なし" : agenda.joined(separator: "\n\n")))
            var table = "## Next Action\n"
            if m.nextActions.isEmpty {
                table += "- なし"
            } else {
                var rows = ["| 内容 | 担当 | 期限 | 出典 |", "|---|---|---|---|"]
                for a in m.nextActions {
                    let source = link(a.t).map { $0.replacingOccurrences(of: "|", with: "\\|") } ?? "—"
                    rows.append("| \(cell(a.text)) | \(cell(a.owner)) | \(cell(a.due)) | \(source) |")
                }
                table += rows.joined(separator: "\n")
            }
            sections.append(table)
        } else {
            sections.append("> 議事録は未生成です。`autonote regenerate \(manifest.id.rawValue)` で作り直せます。")
        }

        let bookmarks = manifest.bookmarks.map { b -> String in
            let l = Self.link(b.at, anchor: TranscriptMarkdown.linkTarget(for: b.at, utterances: utterances, anchors: anchors))
            let note = b.note.map(flat)?.trimmingCharacters(in: .whitespaces) ?? ""
            return note.isEmpty ? l : "\(l) \(note)"
        }
        sections.append("## ブックマーク\n" + list(bookmarks))

        let body = TranscriptMarkdown.render(utterances, pauses: manifest.pauses)
        if body.isEmpty { return sections.joined(separator: "\n\n") + "\n\n## 文字起こし\n" }
        return sections.joined(separator: "\n\n") + "\n\n## 文字起こし\n\n" + body
    }
}
