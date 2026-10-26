import Testing
import Foundation
import AutoNoteCore

@Suite struct RecorderCommandRulesTests {
    @Test(arguments: [(RecorderCommand.bookmark, RecorderState.idle), (.bookmark, .countdown), (.stop, .idle), (.stop, .countdown), (.pause, .idle), (.resume, .idle)])
    func rejectsWhenNotRecording(c: RecorderCommand, s: RecorderState) {
        #expect(throws: AppCommandError.notRecording) { try RecorderCommandRules.check(c, state: s) }
    }

    @Test(arguments: [RecorderState.recording, .paused, .grace])
    func startWhileRecordingIsAlready(s: RecorderState) {
        #expect(throws: AppCommandError.alreadyRecording) { try RecorderCommandRules.check(.start, state: s) }
    }

    @Test func pauseResumeWrongState() {
        #expect(throws: AppCommandError.invalid("すでに一時停止中です")) { try RecorderCommandRules.check(.pause, state: .paused) }
        #expect(throws: AppCommandError.invalid("一時停止中ではありません")) { try RecorderCommandRules.check(.resume, state: .recording) }
        #expect(throws: AppCommandError.invalid("機材が外れているあいだは一時停止できません")) {
            try RecorderCommandRules.check(.pause, state: .grace)
        }
    }

    /// §5.9: a manual start during the countdown discards the countdown.
    @Test func startFromCountdownIsAllowed() throws {
        try RecorderCommandRules.check(.start, state: .countdown)
    }
}
