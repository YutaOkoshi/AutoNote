import Foundation

public struct IndexEntry: Equatable, Sendable {
    public var meetingID: MeetingID
    public var date: String
    public var start: String
    public var title: String
    public var durationMinutes: Int?
    public var firstLine: String
    public var status: String
    /// Relative to the output folder, without the `.md` extension.
    public var linkPath: String

    public init(meetingID: MeetingID, date: String, start: String, title: String, durationMinutes: Int?,
                firstLine: String, status: String, linkPath: String) {
        self.meetingID = meetingID; self.date = date; self.start = start; self.title = title
        self.durationMinutes = durationMinutes; self.firstLine = firstLine; self.status = status; self.linkPath = linkPath
    }
}

public enum IndexFile {
    public static let guide = """
    > **Claude Code への案内**（AutoNote が自動で書き直す。手で編集しても次の更新で消える）
    > - このフォルダは会議の記録で、一会議一ファイル。`YYYY/YYYY-MM-DD_HHMM_<タイトル>.md`（議事録未生成は `YYYY/YYYY-MM-DD_HHMMSS.md`）に置いてある。`_autonote/` はアプリの設定なので読まなくてよい
    > - 各ファイルは frontmatter（title, date, start, end, duration_min, status, autonote_id など）の後に「3行要約」「決定事項」「議題」「Next Action」「ブックマーク」「文字起こし」の節が続く。status が transcript_only のファイルは議事録の節が無い
    > - 文字起こしは一発話一段落の `**[HH:MM:SS] 話者**: 本文 ^tHH-MM-SS`。話者は 自分 / 相手 / 不明。議事録中の `[[#^tHH-MM-SS|MM:SS]]` はその発言へのリンクで、時刻の文字列で検索すれば該当行に行ける
    > - 下の表は新しい順の一覧。まずここで日付とタイトルから対象を絞り、該当ファイルの必要な節だけを読む
    """

    public static func render(_ entries: [IndexEntry]) -> String {
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
        let sorted = entries.sorted {
            let a = $0.date + $0.start, b = $1.date + $1.start
            return a != b ? a > b : $0.linkPath > $1.linkPath
        }
        var lines = ["# 会議一覧", "", guide, "", "| 日付 | 時刻 | タイトル | 長さ | 一行目 | ファイル |", "|---|---|---|---|---|---|"]
        for e in sorted {
            let length = e.durationMinutes.map { "\($0) 分" } ?? "—"
            lines.append("| \(e.date) | \(e.start) | \(cell(e.title)) | \(length) | \(cell(e.firstLine)) | [[\(e.linkPath)]] |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
