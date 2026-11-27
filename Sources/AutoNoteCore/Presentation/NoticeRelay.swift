import Foundation

/// Pure rules that turn recorder events and queue changes into notices. Holds no state: first-snapshot seeding and
/// de-duplication belong to the caller (`AppEnvironment`).
public enum NoticeRelay {
    public static func notices(for e: RecordingEvent) -> [UserNotice] {
        switch e {
        case .silenceWarning(let w): [.silence(w.track)]
        case .diskSpaceLow(let bytes): [.diskLow(availableBytes: bytes)]
        case .sourceFailed(let track, _): [.recordingLoss(track, reason: .sourceFailed)]
        case .audioNotArriving(let track, _, let heardBefore):
            [.recordingLoss(track, reason: heardBefore ? .notArriving : .nothingArrived)]
        default: []
        }
    }

    /// Notices (by id) that an event makes untrue. Only one notice about a track at a time: "not arriving" takes the
    /// place of the general silence warning and is itself taken back when audio is heard again; a failure takes the
    /// place of both and is taken back when the track records again. Nothing about a recording outlives it.
    public static func withdrawals(for e: RecordingEvent) -> [String] {
        switch e {
        case .audioNotArriving(.system, _, _): [UserNotice.silence(.system).id]
        case .audioArrivingAgain(let track): notArriving(track)
        case .sourceFailed(let track, _): notArriving(track) + [UserNotice.silence(track).id]
        case .sourceRecovered(let track): [UserNotice.recordingLoss(track, reason: .sourceFailed).id]
        case .stopped:
            [Track.mic, .system].flatMap { notArriving($0) + [UserNotice.recordingLoss($0, reason: .sourceFailed).id] }
        default: []
        }
    }

    private static func notArriving(_ track: Track) -> [String] {
        [RecordingLossReason.notArriving, .nothingArrived].map { UserNotice.recordingLoss(track, reason: $0).id }
    }

    public static func notices(previous: QueueStatus, current: QueueStatus, rows: [MeetingRow]) -> [UserNotice] {
        var out: [UserNotice] = []
        let currentIDs = Set(current.items.map(\.meetingID))
        let previousByID = Dictionary(previous.items.map { ($0.meetingID, $0) }, uniquingKeysWith: { _, last in last })

        // (a) A job that left the queue: report the outcome by its meeting row.
        for item in previous.items where !currentIDs.contains(item.meetingID) {
            guard let row = rows.first(where: { $0.id == item.meetingID }) else { continue }
            let id = MeetingID(rawValue: item.meetingID)
            switch row.state {
            case .minutesGenerated: out.append(.minutesGenerated(id, title: row.title))
            case .transcriptOnly: out.append(.transcriptOnly(id))
            default: break
            }
        }
        for item in current.items {
            let id = MeetingID(rawValue: item.meetingID)
            let before = previousByID[item.meetingID]
            // (b) A summary failure the job did not have before.
            if let failure = item.summaryFailure, failure != before?.summaryFailure {
                out.append(failure == SummaryFailureKind.notLoggedIn.rawValue ? .claudeNotLoggedIn(id) : .transcriptOnly(id))
            }
            // (c) The job started waiting for an overwrite decision.
            if item.awaitingConfirmation && !(before?.awaitingConfirmation ?? false) {
                out.append(.overwriteConfirmation(id))
            }
        }
        return out
    }

    public static func notices(outputFolderWasAvailable: Bool, isAvailable: Bool) -> [UserNotice] {
        outputFolderWasAvailable && !isAvailable ? [.outputFolderMissing] : []
    }
}
