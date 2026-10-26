import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct WakeSuppressionTests {
    let bt = DeviceIdentity(raw: .fixtureBluetoothInput)!
    let jack = DeviceIdentity(raw: .fixtureHeadphoneInput)!

    @Test func reappearanceInsideWindowIsSwallowed() {
        var w = WakeSuppression(); w.didWake(present: [bt.deviceUID])
        #expect(w.filter(added: [], removed: [bt]) == ([], []))
        #expect(w.filter(added: [bt], removed: []) == ([], []))
        #expect(w.endWindow(current: [bt]) == [.present(bt, .wake)])
        #expect(!w.inWindow)
    }

    @Test func removalNotRecoveredIsEmittedAtWindowEnd() {
        var w = WakeSuppression(); w.didWake(present: [bt.deviceUID])
        #expect(w.filter(added: [], removed: [bt]) == ([], []))
        #expect(w.endWindow(current: []) == [.removed(bt)])
    }

    @Test func newDeviceInsideWindowIsAdded() {
        var w = WakeSuppression(); w.didWake(present: [bt.deviceUID])
        #expect(w.inWindow)
        #expect(w.filter(added: [jack], removed: []) == ([jack], []))
        #expect(w.filter(added: [], removed: [jack]) == ([], [jack]))
        // Window end only reports devices that were connected before sleep.
        #expect(w.endWindow(current: [bt]) == [.present(bt, .wake)])
    }

    @Test func outsideWindowPassesThrough() {
        var w = WakeSuppression()
        #expect(!w.inWindow)
        #expect(w.filter(added: [bt], removed: [jack]) == ([bt], [jack]))
        #expect(w.endWindow(current: [bt]) == [])
        w.didWake(present: [bt.deviceUID])
        _ = w.endWindow(current: [bt])
        #expect(w.filter(added: [bt], removed: []) == ([bt], []))
        #expect(w.filter(added: [], removed: [bt]) == ([], [bt]))
        #expect(w.endWindow(current: []) == [])
    }

    @Test func secondWakeKeepsHeldRemovals() {
        var w = WakeSuppression(); w.didWake(present: [bt.deviceUID])
        _ = w.filter(added: [], removed: [bt])
        w.didWake(present: [])                       // slept again while bt was still gone
        #expect(w.filter(added: [bt], removed: []) == ([], []))
        #expect(w.endWindow(current: [bt]) == [.present(bt, .wake)])
    }
}
