import Foundation
import AutoNoteCore

/// Utterance shorthand for tests (`isFinal: true`).
public func u(_ seconds: Double, _ speaker: Speaker, _ text: String, end: Double? = nil) -> Utterance {
    Utterance(start: TimelineTime(seconds: seconds), end: end.map { TimelineTime(seconds: $0) },
              speaker: speaker, text: text, isFinal: true)
}

public enum Samples {
    public static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// 2026-10-24T05:00:00Z = 14:00 in Tokyo.
    public static let start = Date(timeIntervalSince1970: 1_792_818_000)

    public static var manifest: Manifest {
        Manifest(
            id: MeetingID(rawValue: "20261024-1400-a1b2"), title: nil,
            startedAt: start, endedAt: start.addingTimeInterval(62 * 60),
            source: .live,
            device: DeviceRef(name: "Kestrel Headset 7", uid: "FAKE-KESTREL-0001:input", transport: "bluetooth"),
            language: .ja, tracks: [], pauses: [], bookmarks: [],
            status: .minutesGenerated, silenceWarning: false, autonoteVersion: "0.1.0")
    }

    public static var minutes: MinutesOutput {
        MinutesOutput(
            title: "プロジェクト定例",
            summary: ["リリースは来週に決定", "ドキュメントの更新が残っている", "次回は来週同時刻"],
            decisions: [Decision(text: "リリースは来週に出す", t: "00:12:34")],
            agenda: [AgendaItem(title: "リリース判定", body: "品質状況を確認し、来週の出荷で合意した。", t: "00:03:10")],
            nextActions: [NextAction(text: "ドキュメント更新", owner: "自分", due: "10/31", t: "00:40:02")],
            suggestedTerms: [])
    }
}
