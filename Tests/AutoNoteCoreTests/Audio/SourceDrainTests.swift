import Testing
import Foundation
@testable import AutoNoteCore

@Suite struct SourceDrainTests {
    @Test func runAwaitingReturnsFalseWhenWorkOutlastsTimeout() async {
        let queue = DispatchQueue(label: "test.runAwaiting.slow")
        let t0 = ContinuousClock.now
        let finished = await queue.runAwaiting(timeout: .milliseconds(50)) { Thread.sleep(forTimeInterval: 1) }
        #expect(finished == false)
        #expect(ContinuousClock.now - t0 < .milliseconds(800))
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
