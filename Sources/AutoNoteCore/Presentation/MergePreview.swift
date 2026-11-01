import Foundation

/// What the window's 「1 つの会議に統合」 confirmation shows: the combined meeting's start, end and the time
/// between the recordings. Built by `MeetingCombiner.plan`, so it refuses exactly what the merge itself refuses.
public struct MergePreview: Equatable, Sendable {
    public static let title = "1 つの会議に統合しますか？"

    public var count: Int
    public var startedAt: Date
    public var endedAt: Date
    public var gapSeconds: Double

    public init(count: Int, startedAt: Date, endedAt: Date, gapSeconds: Double) {
        self.count = count; self.startedAt = startedAt; self.endedAt = endedAt; self.gapSeconds = gapSeconds
    }

    /// `queue` marks the meetings with an active job as processing (`QueueStatus.activeMeetingIDs`).
    public static func make(_ manifests: [Manifest], queue: QueueStatus = .empty) throws(CombineError) -> MergePreview {
        // The id is a placeholder: the preview never creates anything.
        let plan = try MeetingCombiner.plan(manifests, newID: MeetingID(rawValue: "preview"), busy: queue.activeMeetingIDs)
        return MergePreview(count: plan.sources.count, startedAt: plan.manifest.startedAt,
                            endedAt: plan.manifest.endedAt ?? plan.manifest.startedAt, gapSeconds: plan.gapSeconds)
    }

    public func message(timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(startedAt, inSameDayAs: endedAt)
        return """
            \(count) 件の録音を 1 つの会議にまとめ、文字起こしからやり直します。
            開始 \(Self.format(startedAt, "yyyy/MM/dd HH:mm:ss", timeZone)) → 終了 \(Self.format(endedAt, sameDay ? "HH:mm:ss" : "yyyy/MM/dd HH:mm:ss", timeZone))（隙間の合計 \(Self.gapText(gapSeconds))）
            元の会議は一覧と Vault から外れます（録音ファイルは残ります）。
            """
    }

    /// "1.6 秒" is shown as "2 秒": whole seconds; hours and minutes from an hour on.
    static func gapText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 3600 { return DurationText.spoken(s) }
        let m = s / 60
        return m % 60 == 0 ? "\(m / 60) 時間" : "\(m / 60) 時間 \(m % 60) 分"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

extension QueueStatus {
    /// Meetings whose job is pending, running or waiting (not failed, not done): `merge` refuses them.
    public var activeMeetingIDs: Set<MeetingID> {
        let active: Set<String> = [JobState.pending.rawValue, JobState.running.rawValue, JobState.waiting.rawValue]
        return Set(items.filter { active.contains($0.state) }.map { MeetingID(rawValue: $0.meetingID) })
    }
}
