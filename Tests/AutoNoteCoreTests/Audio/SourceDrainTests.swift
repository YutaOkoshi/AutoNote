import Testing
import Foundation
@testable import AutoNoteCore

@Suite struct SourceDrainTests {
    @Test func runAwaitingReturnsFalseWhenWorkOutlastsTimeout() async {
        let queue = DispatchQueue(label: "test.runAwaiting.slow")
        let t0 = ContinuousClock.now
        // Work 10× the timeout; the bound leaves 4 s of scheduler slack and still sits well before the work ends.
        let finished = await queue.runAwaiting(timeout: .seconds(1)) { Thread.sleep(forTimeInterval: 10) }
        #expect(finished == false)
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }

    @Test func runAwaitingReturnsTrueWhenWorkFinishesInTime() async {
        let queue = DispatchQueue(label: "test.runAwaiting.fast")
        let finished = await queue.runAwaiting(timeout: .seconds(5)) {}
        #expect(finished == true)
    }

    @Test func resumeGateRecordsTheFirstOutcomeOnly() {
        let gate = ResumeGate()
        #expect(gate.fire(timedOut: true))
        #expect(!gate.fire(timedOut: false))
        #expect(gate.timedOut)
    }
}
