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
            sections += Self.minutesSections(m, flat: flat, link: link, withLink: withLink, cell: cell, list: list)
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

    /// The minutes sections in the schema v2 order (spec F2 §3.3). 議題・要約・決定事項・アクション are always written
    /// (「- なし」 when empty, as before v2); every other section only when it has content, so a v1 file renders the same
    /// sections as before.
    private static func minutesSections(_ m: MinutesOutput, flat: (String) -> String, link: (String) -> String?,
                                        withLink: (String, String) -> String, cell: (String?) -> String,
                                        list: ([String]) -> String) -> [String] {
        func optional(_ s: String?) -> String? {
            guard let s else { return nil }
            let f = flat(s).trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? nil : f
        }
        func linked(_ text: String, _ t: String) -> String { link(t).map { "\(text) \($0)" } ?? text }
        var out: [String] = []
        if !m.attendees.isEmpty {
            let names = m.attendees.map { a in optional(a.role).map { "\(flat(a.name))（\($0)）" } ?? flat(a.name) }
            out.append("## 出席者\n" + names.joined(separator: "、"))
        }
        let agenda = m.agenda.enumerated().map { "### \($0.offset + 1). \(flat($0.element.title))\n\(withLink($0.element.body, $0.element.t))" }
        out.append("## 議題\n" + (agenda.isEmpty ? "- なし" : agenda.joined(separator: "\n\n")))
        let paragraphs = m.summary.map(flat).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        out.append("## 要約\n" + (paragraphs.isEmpty ? "- なし" : paragraphs.joined(separator: "\n\n")))
        if !m.keyPoints.isEmpty { out.append("## 重要ポイント\n" + list(m.keyPoints.map { withLink($0.text, $0.t) })) }
        out.append("## 決定事項\n" + list(m.decisions.map { withLink($0.text, $0.t) }))
        var table = "## アクション\n"
        if m.nextActions.isEmpty {
            table += "- なし"
        } else {
            var rows = ["| 優先度 | 内容 | 担当 | 期限 | 出典 |", "|---|---|---|---|---|"]
            for a in m.nextActions {
                let source = link(a.t).map { $0.replacingOccurrences(of: "|", with: "\\|") } ?? "—"
                rows.append("| \(MinutesPresentation.levelText(a.priority)) | \(cell(a.text)) | \(cell(a.owner)) | \(cell(a.due)) | \(source) |")
            }
            table += rows.joined(separator: "\n")
        }
        out.append(table)
        if !m.questions.isEmpty {
            let lines = m.questions.map { q -> String in
                var line = "- [\(q.isResolved ? "x" : " ")] \(flat(q.question))"
                if let by = optional(q.askedBy) { line += " — \(by)" }
                line = linked(line, q.t)
                if let answer = optional(q.answer) { line += "\n  → \(answer)" }
                return line
            }
            out.append("## 質問\n" + lines.joined(separator: "\n"))
        }
        if !m.deadlines.isEmpty {
            out.append("## 締め切り\n" + list(m.deadlines.map { d in
                var line = "\(flat(d.description)) — \(flat(d.date))"
                if let owner = optional(d.owner) { line += "（\(owner)）" }
                return linked(line, d.t)
            }))
        }
        if !m.followUps.isEmpty { out.append("## フォローアップ\n" + list(m.followUps.map { withLink($0.text, $0.t) })) }
        if !m.risks.isEmpty {
            out.append("## リスク\n" + list(m.risks.map { r in
                var line = "\(MinutesPresentation.severityEmoji(r.severity)) \(flat(r.description))"
                if let mitigation = optional(r.mitigation) { line += " — 対策: \(mitigation)" }
                return linked(line, r.t)
            }))
        }
        if !m.insights.isEmpty { out.append("## インサイト\n" + list(m.insights.map { withLink($0.text, $0.t) })) }
        if let diagram = MinutesPresentation.diagramSource(m.architectureDiagram) {
            out.append("## 構成図\n```mermaid\n\(diagram)\n```")
        }
        return out
    }
}
