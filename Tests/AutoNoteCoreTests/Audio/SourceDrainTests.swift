import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct SourceDrainTests {
    @Test func runAwaitingReturnsFalseWhenWorkOutlastsTimeout() async {
        // The work does not end until released, so only the timeout can end the wait.
        let queue = DispatchQueue(label: "test.runAwaiting.slow")
        let work = BlockingHold(); work.hold()
        defer { work.release() }
        let finished = await queue.runAwaiting(timeout: .milliseconds(200)) { work.wait() }
        #expect(finished == false)
        #expect(!work.expired)
    }

    @Test func runAwaitingReturnsTrueWhenWorkFinishesInTime() async {
        let queue = DispatchQueue(label: "test.runAwaiting.fast")
        let finished = await queue.runAwaiting(timeout: testPatience) {}
        #expect(finished == true)
    }

    @Test func resumeGateRecordsTheFirstOutcomeOnly() {
        let gate = ResumeGate()
        #expect(gate.fire(timedOut: true))
        #expect(!gate.fire(timedOut: false))
        #expect(gate.timedOut)
    }
}
