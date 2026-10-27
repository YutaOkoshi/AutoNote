import Foundation

/// Builds the meeting list from the Vault index (`VaultScanner`), the app's manifests and the queue.
/// A meeting appears when either side knows it: the Vault keeps meetings whose app data is gone, the
/// manifests keep meetings not yet written to the Vault (recording, processing, no output folder).
public enum MeetingListBuilder {
    public static let untitled = "（無題）"
    public static let waitingLabel = "処理待ち"

    /// A meeting the output folder does not hold (it was written to a previous output folder) keeps the title and
    /// path of the note last written, while that file exists (`fileExists`).
    public static func build(index: [IndexEntry], manifests: [Manifest], queue: QueueStatus, outputFolder: URL?,
                             timeZone: TimeZone = .current,
                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [MeetingRow] {
        let entries = Dictionary(index.map { ($0.meetingID, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(manifests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let jobs = Dictionary(queue.items.map { ($0.meetingID, $0) }, uniquingKeysWith: { _, b in b })
        let ids = Set(entries.keys).union(byID.keys)

        let rows = ids.map { id -> MeetingRow in
            let entry = entries[id]
            let manifest = byID[id]
            var row = MeetingRow(id: id.rawValue)
            row.title = entry?.title ?? manifest?.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? manifest?.noteTitle.flatMap { $0.isEmpty ? nil : $0 } ?? untitled
            row.startedAt = manifest?.startedAt ?? entry.flatMap { parseStart($0, timeZone: timeZone) } ?? Date(timeIntervalSince1970: 0)
            row.durationMinutes = entry?.durationMinutes ?? manifest?.duration.map { Int(($0 / 60).rounded()) }
            row.durationSeconds = manifest?.duration.map { Int($0.rounded(.down)) }
            row.state = manifest.map { state(of: $0.status) } ?? state(ofIndexStatus: entry?.status ?? "")
            if row.state == .processing { row.progressLabel = waitingLabel }
            if let entry, let outputFolder {
                row.filePath = outputFolder.appending(path: "\(entry.linkPath).md").path
            } else if let path = manifest?.notePath, fileExists(path) {
                row.filePath = path
            }
            row.silenceWarning = manifest?.silenceWarning ?? false
            row.summaryFirstLine = entry.flatMap { $0.firstLine.isEmpty ? nil : $0.firstLine }
            if let job = jobs[id.rawValue] { apply(job, to: &row) }
            return row
        }
        return rows.sorted { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id > $1.id }
    }

    /// Rows started on or after the start of `since` (`YYYY-MM-DD`) in `calendar`'s time zone.
    public static func filter(_ rows: [MeetingRow], since: String, calendar: Calendar) throws(AppCommandError) -> [MeetingRow] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard since.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, let day = f.date(from: since) else {
            throw .invalid("日付は YYYY-MM-DD で指定してください: \(since)")
        }
        let start = calendar.startOfDay(for: day)
        return rows.filter { $0.startedAt >= start }
    }

    /// Ruling X28.
    static func state(of status: MeetingStatus) -> MeetingRowState {
        switch status {
        case .recording: .recording
        case .recorded, .transcribing, .transcribed, .generating: .processing
        case .minutesGenerated: .minutesGenerated
        case .transcriptOnly: .transcriptOnly
        case .failed: .failed
        case .tooShort: .tooShort
        }
    }

    static func state(ofIndexStatus status: String) -> MeetingRowState {
        switch status {
        case "transcript_only": .transcriptOnly
        case "failed": .failed
        default: .minutesGenerated
        }
    }

    /// An active job (pending, running, waiting) shows the meeting as processing with the queue's label;
    /// a failed job shows it as failed. Done jobs (kept only for their `summaryFailure`) change nothing.
    private static func apply(_ job: QueueItemDTO, to row: inout MeetingRow) {
        switch job.state {
        case JobState.running.rawValue, JobState.pending.rawValue, JobState.waiting.rawValue:
            row.state = .processing
            if job.notBefore != nil {
                row.progressLabel = "再試行待ち"
            } else if job.awaitingConfirmation {
                row.progressLabel = "上書きの確認待ち"
            } else {
                row.progressLabel = job.label.isEmpty ? waitingLabel : job.label
            }
        case JobState.failed.rawValue:
            row.state = .failed
            row.progressLabel = nil
        default:
            break
        }
    }

    private static func parseStart(_ entry: IndexEntry, timeZone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = f.date(from: "\(entry.date) \(entry.start)") { return d }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: entry.date)
    }
}
