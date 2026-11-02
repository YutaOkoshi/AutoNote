import Testing
import Foundation
import AutoNoteCore

@Suite struct MeetingContextMenuTests {
    private func row(_ id: String, _ state: MeetingRowState, filePath: String? = nil) -> MeetingRow {
        MeetingRow(id: id, title: "会議 \(id)", state: state, filePath: filePath)
    }

    private func failure(_ name: String, meeting: String) -> AutomationRunRecord {
        AutomationRunRecord(name: name, event: .minutesGenerated, meetingID: meeting, startedAt: Date(timeIntervalSince1970: 0),
                            durationSeconds: 1, exitCode: 1, timedOut: false, skippedReason: nil, logDirectory: "/tmp/x")
    }

    private let rows: [MeetingRow] = [
        MeetingRow(id: "done", state: .minutesGenerated, filePath: "/vault/done.md"),
        MeetingRow(id: "transcript", state: .transcriptOnly),
        MeetingRow(id: "busy", state: .processing),
        MeetingRow(id: "queued", state: .recorded),
        MeetingRow(id: "rec", state: .recording),
        MeetingRow(id: "bad", state: .failed),
        MeetingRow(id: "short", state: .tooShort),
    ]

    @Test func twoOrMoreSelectedOffersOnlyTheMerge() {
        let actions = MeetingContextMenu.actions(selected: ["done", "busy"], rows: rows,
                                                 automationFailures: [failure("slack", meeting: "done")])
        #expect(actions == [.merge])
    }

    @Test func nothingSelectedOffersNothing() {
        #expect(MeetingContextMenu.actions(selected: [], rows: rows, automationFailures: []).isEmpty)
    }

    @Test func aCompletedMeetingOffersRegenerateRevealAndDelete() {
        #expect(MeetingContextMenu.actions(selected: ["done"], rows: rows, automationFailures: [])
                == [.regenerate, .revealInFinder, .delete])
    }

    @Test func aTranscriptOnlyMeetingCanBeRegeneratedToo() {
        #expect(MeetingContextMenu.actions(selected: ["transcript"], rows: rows, automationFailures: [])
                == [.regenerate, .revealInFinder, .delete])
    }

    @Test func aProcessingOrRecordingMeetingOffersOnlyReveal() {
        for id in ["busy", "queued", "rec"] {
            #expect(MeetingContextMenu.actions(selected: [id], rows: rows, automationFailures: []) == [.revealInFinder])
        }
    }

    @Test func aFailedOrTooShortMeetingCanBeRevealedAndDeletedButNotRegenerated() {
        for id in ["bad", "short"] {
            #expect(MeetingContextMenu.actions(selected: [id], rows: rows, automationFailures: []) == [.revealInFinder, .delete])
        }
    }

    @Test func failedAutomationsOfThatMeetingComeFirst() {
        let failures = [failure("slack", meeting: "done"), failure("other", meeting: "bad"), failure("mail", meeting: "done")]
        #expect(MeetingContextMenu.actions(selected: ["done"], rows: rows, automationFailures: failures)
                == [.rerunAutomation("slack"), .rerunAutomation("mail"), .regenerate, .revealInFinder, .delete])
    }

    @Test func aMeetingNoLongerListedOffersOnlyItsReruns() {
        #expect(MeetingContextMenu.actions(selected: ["gone"], rows: rows,
                                           automationFailures: [failure("slack", meeting: "gone")]) == [.rerunAutomation("slack")])
    }

    @Test func titlesAndSymbols() {
        #expect(MeetingContextAction.merge.title == "1 つの会議に統合")
        #expect(MeetingContextAction.merge.systemImage == "rectangle.stack.badge.plus")
        #expect(MeetingContextAction.regenerate.title == "再生成")
        #expect(MeetingContextAction.regenerate.systemImage == "arrow.clockwise")
        #expect(MeetingContextAction.revealInFinder.title == "Finder で表示")
        #expect(MeetingContextAction.revealInFinder.systemImage == "folder")
        #expect(MeetingContextAction.delete.title == "この会議を削除")
        #expect(MeetingContextAction.delete.systemImage == "trash")
        #expect(MeetingContextAction.rerunAutomation("slack").title == "再実行: slack")
        #expect(MeetingContextAction.rerunAutomation("slack").systemImage == "arrow.clockwise")
        #expect(MeetingContextAction.delete.isDestructive)
        #expect(![MeetingContextAction.merge, .regenerate, .revealInFinder, .rerunAutomation("x")].contains { $0.isDestructive })
    }

    @Test func revealShowsTheNoteOrElseTheRecordingFolder() {
        let tracks = URL(filePath: "/data/meetings/x/tracks", directoryHint: .isDirectory)
        #expect(MeetingContextMenu.revealURL(for: row("x", .minutesGenerated, filePath: "/vault/x.md"), tracksDirectory: tracks)
                == URL(filePath: "/vault/x.md"))
        #expect(MeetingContextMenu.revealURL(for: row("x", .processing), tracksDirectory: tracks) == tracks)
        #expect(MeetingContextMenu.revealURL(for: nil, tracksDirectory: tracks) == tracks)
    }
}
