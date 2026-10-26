import Testing
import AutoNoteCore

@Suite struct QuitPolicyTests {
    @Test func quitDecisions() {
        #expect(QuitPolicy.decide(.idle, reason: .user) == .terminateNow && QuitPolicy.decide(.countdown, reason: .user) == .cancelCountdownThenTerminate)
        for s in [RecorderState.recording, .paused, .grace] { #expect(QuitPolicy.decide(s, reason: .user) == .confirm && QuitPolicy.decide(s, reason: .powerOff) == .stopThenTerminate) }
        #expect(QuitPolicy.decide(.idle, reason: .powerOff) == .terminateNow && QuitPolicy.decide(.countdown, reason: .powerOff) == .cancelCountdownThenTerminate)
        #expect(QuitPolicy.confirmMessage == "録音中です。停止して終了しますか？")
    }
}
