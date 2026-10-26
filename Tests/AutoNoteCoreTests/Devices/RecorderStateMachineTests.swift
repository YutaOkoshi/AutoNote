import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

typealias Table = RecorderTransitionTable

@Test func tableHasEveryCell() { #expect(Table.cells.count == 112) }

@Test(arguments: Table.cells)
func transition(_ cell: Table.Cell) {
    var m = Table.machine(in: cell.from)
    let (state, effects) = m.apply(Table.event(cell.column, for: m))
    #expect(state == cell.to.state); #expect(m.state == cell.to.state)
    #expect(m.trigger == cell.to.trigger); #expect(m.origin == cell.to.origin)
    #expect(m.originEntryID == cell.to.originEntryID); #expect(m.pendingTimerToken == cell.to.pendingTimerToken)
    #expect(effects == cell.effects)
}

@Test func noChangeCellsLeaveEverythingUntouched() {
    var m = Table.machine(in: .RA)
    let before = (m.state, m.trigger, m.origin, m.originEntryID, m.pendingTimerToken)
    let (_, effects) = m.apply(.timerFired(token: 99))
    #expect(effects.isEmpty)
    #expect(m.state == before.0); #expect(m.trigger == before.1); #expect(m.origin == before.2)
    #expect(m.originEntryID == before.3); #expect(m.pendingTimerToken == before.4)
}

@Test func zeroCountdownStartsImmediately() {
    var m = RecorderStateMachine(config: AutoRecordConfig(countdownSeconds: 0, graceSeconds: 30, language: .auto, startOnModelMatch: true))
    let (state, effects) = m.apply(.deviceConnected(Table.deviceA, autoStartEntryID: "eA"))
    #expect(state == .recording); #expect(m.trigger == .auto); #expect(m.origin == Table.deviceA)
    #expect(effects == [.startRecording(.device(Table.deviceA), .auto)])
    #expect(m.pendingTimerToken == nil)
}

@Test func configIsClamped() {
    func c(_ cd: Int, _ gr: Int) -> AutoRecordConfig {
        AutoRecordConfig(countdownSeconds: cd, graceSeconds: gr, language: .ja, startOnModelMatch: false)
    }
    #expect(c(45, 30).countdownSeconds == 30); #expect(c(-1, 30).countdownSeconds == 0)
    #expect(c(5, 0).graceSeconds == 5); #expect(c(5, 1000).graceSeconds == 300)
    #expect(c(5, 30).countdownSeconds == 5); #expect(c(5, 30).graceSeconds == 30)
}

@Test func staleGraceTimerAfterFlapIsIgnored() {
    var m = Table.machine(in: .RA)
    #expect(m.apply(.deviceDisconnected(Table.deviceA)).1.contains(.scheduleTimer(seconds: 30, token: 2)))
    _ = m.apply(.deviceConnected(Table.deviceA, autoStartEntryID: "eA"))
    #expect(m.state == .recording)
    let (s3, e3) = m.apply(.deviceDisconnected(Table.deviceA))
    #expect(s3 == .grace); #expect(e3 == [.suspendMicrophone, .scheduleTimer(seconds: 30, token: 3), .showGraceBanner(seconds: 30)])
    let (s2, e2) = m.apply(.timerFired(token: 2))
    #expect(s2 == .grace); #expect(e2.isEmpty)
    let (s, e) = m.apply(.timerFired(token: 3))
    #expect(s == .idle); #expect(e == [.clearGraceBanner, .stopRecording])
}

@Test func graceReturnByEntryIDCountsAsSameDevice() {
    var m = Table.machine(in: .GR)
    var moved = Table.deviceA; moved.deviceUID = "00-11-22-33-44-55:input-other-port"
    let (state, effects) = m.apply(.deviceConnected(moved, autoStartEntryID: "eA"))
    #expect(state == .recording)
    #expect(effects == [.cancelTimer, .clearGraceBanner, .reattachMicrophone(moved)])
    #expect(m.origin == moved)
}

@Test func twoDevicesAtOnceCountDownOnlyFirst() {
    var m = RecorderStateMachine(config: Table.config)
    let (_, e1) = m.apply(.deviceConnected(Table.deviceA, autoStartEntryID: "eA"))
    let (s2, e2) = m.apply(.deviceConnected(Table.deviceB, autoStartEntryID: "eB"))
    #expect(e1 == [.postCountdownNotice(Table.deviceA, seconds: 5), .scheduleTimer(seconds: 5, token: 1)])
    #expect(s2 == .countdown); #expect(e2.isEmpty); #expect(m.origin == Table.deviceA)
}

@Test func needsQuitConfirmationWhileRecordingPausedOrGrace() {
    for c in Table.Config.allCases {
        let expected = ![.I, .CD].contains(c)
        #expect(Table.machine(in: c).needsQuitConfirmation == expected, "\(c.rawValue)")
    }
}

@Test func usesConfiguredSecondsInEffects() {
    var m = RecorderStateMachine(config: AutoRecordConfig(countdownSeconds: 10, graceSeconds: 45, language: .en, startOnModelMatch: true))
    let (_, e1) = m.apply(.deviceConnected(Table.deviceA, autoStartEntryID: "eA"))
    #expect(e1 == [.postCountdownNotice(Table.deviceA, seconds: 10), .scheduleTimer(seconds: 10, token: 1)])
    _ = m.apply(.timerFired(token: 1))
    let (_, e2) = m.apply(.deviceDisconnected(Table.deviceA))
    #expect(e2 == [.suspendMicrophone, .scheduleTimer(seconds: 45, token: 2), .showGraceBanner(seconds: 45)])
}

// MARK: - I2 / Y26: a USB unit of the same model and name returning during grace is the origin's return.

private let usbOrigin = DeviceIdentity(raw: .fixtureUSBInput(uid: "AppleUSBAudioEngine:Fictional:Audio:14100000:1"))!
private let usbOtherPort = DeviceIdentity(raw: .fixtureUSBInput(uid: "AppleUSBAudioEngine:Fictional:Audio:14132000:1"))!

/// Auto-recording from `usbOrigin`, unplugged into grace (from recording, or from paused when `paused`).
private func usbMachineInGrace(paused: Bool) -> RecorderStateMachine {
    var m = RecorderStateMachine(config: Table.config)
    _ = m.apply(.deviceConnected(usbOrigin, autoStartEntryID: "eU"))
    _ = m.apply(.timerFired(token: 1))
    if paused { _ = m.apply(.pause) }
    _ = m.apply(.deviceDisconnected(usbOrigin))
    return m
}

@Test func usbReplugOnOtherPortDuringGraceReturnsToRecording() {
    var m = usbMachineInGrace(paused: false)
    #expect(m.state == .grace)
    let (state, effects) = m.apply(.deviceConnected(usbOtherPort, autoStartEntryID: nil))
    #expect(state == .recording)
    #expect(effects == [.cancelTimer, .clearGraceBanner, .reattachMicrophone(usbOtherPort)])
    #expect(m.origin == usbOtherPort)
    #expect(m.originEntryID == "eU")
    #expect(m.pendingTimerToken == nil)
}

@Test func usbReplugOnOtherPortDuringGraceFromPausedReturnsToPaused() {
    var m = usbMachineInGrace(paused: true)
    #expect(m.state == .grace)
    let (state, effects) = m.apply(.deviceConnected(usbOtherPort, autoStartEntryID: nil))
    #expect(state == .paused)
    #expect(effects == [.cancelTimer, .clearGraceBanner, .reattachMicrophone(usbOtherPort)])
    #expect(m.origin == usbOtherPort)
}

@Test func bluetoothWithOtherUIDAndSameNameIsNotTheOriginsReturn() {
    var m = Table.machine(in: .GR)
    var other = Table.deviceA; other.deviceUID = "66-77-88-99-AA-BB:input"
    let (state, effects) = m.apply(.deviceConnected(other, autoStartEntryID: nil))
    #expect(state == .grace); #expect(effects.isEmpty); #expect(m.origin == Table.deviceA)
}

@Test func usbReturnNeedsSameNameAndARealModelUID() {
    var renamed = usbOtherPort; renamed.name = "Fictional Other Headset"
    var zeroModel = usbOtherPort; zeroModel.modelUID = "0 0"
    var noModel = usbOtherPort; noModel.modelUID = nil
    var bluetooth = usbOtherPort; bluetooth.transport = .bluetooth
    for candidate in [renamed, zeroModel, noModel, bluetooth] {
        var m = usbMachineInGrace(paused: false)
        let (state, effects) = m.apply(.deviceConnected(candidate, autoStartEntryID: nil))
        #expect(state == .grace, "\(candidate)"); #expect(effects.isEmpty)
    }
    // An origin without a real model UID never matches another UID either.
    var zeroOrigin = RecorderStateMachine(config: Table.config)
    var origin0 = usbOrigin; origin0.modelUID = "0 0"
    var return0 = usbOtherPort; return0.modelUID = "0 0"
    _ = zeroOrigin.apply(.deviceConnected(origin0, autoStartEntryID: "eU"))
    _ = zeroOrigin.apply(.timerFired(token: 1))
    _ = zeroOrigin.apply(.deviceDisconnected(origin0))
    #expect(zeroOrigin.apply(.deviceConnected(return0, autoStartEntryID: nil)).0 == .grace)
}
