import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

/// Spec §5.9 as data: 8 configurations x 14 events = 112 cells. Cells not listed in `overrides` mean
/// "nothing changes, no effects". GP c1 follows Lead ruling Y7b (back to paused; no resume).
enum RecorderTransitionTable {
    static let deviceA = DeviceIdentity(raw: .fixtureBluetoothInput)!
    static let deviceB = DeviceIdentity(raw: .fixtureUSBInput(uid: "AppleUSBAudioEngine:Fictional:Audio:SERIAL-B:1"))!
    static let deviceU = DeviceIdentity(raw: .fixtureHeadphoneInput)!

    enum Config: String, CaseIterable, Sendable { case I, CD, RA, RM, PA, PM, GR, GP }

    struct Snapshot: Sendable {
        var state: RecorderState
        var trigger: RecordingTrigger?
        var origin: DeviceIdentity?
    }

    struct Cell: Sendable, CustomTestStringConvertible {
        var from: Config
        var column: Int
        var to: Snapshot
        var effects: [RecorderEffect]
        var testDescription: String { "\(from.rawValue) c\(column)" }
    }

    static func snapshot(of config: Config) -> Snapshot {
        switch config {
        case .I: return Snapshot(state: .idle, trigger: nil, origin: nil)
        case .CD: return Snapshot(state: .countdown, trigger: nil, origin: deviceA)
        case .RA: return Snapshot(state: .recording, trigger: .auto, origin: deviceA)
        case .RM: return Snapshot(state: .recording, trigger: .manual, origin: nil)
        case .PA: return Snapshot(state: .paused, trigger: .auto, origin: deviceA)
        case .PM: return Snapshot(state: .paused, trigger: .manual, origin: nil)
        case .GR, .GP: return Snapshot(state: .grace, trigger: .auto, origin: deviceA)
        }
    }

    static let config = AutoRecordConfig(countdownSeconds: 5, graceSeconds: 30, language: .auto, startOnModelMatch: true)

    static func machine(in config: Config) -> RecorderStateMachine {
        var m = RecorderStateMachine(config: Self.config)
        func feed(_ column: Int) { _ = m.apply(event(column, for: m)) }
        switch config {
        case .I: break
        case .CD: feed(1)
        case .RA: feed(1); feed(6)
        case .RM: feed(9)
        case .PA: feed(1); feed(6); feed(11)
        case .PM: feed(9); feed(11)
        case .GR: feed(1); feed(6); feed(4)
        case .GP: feed(1); feed(6); feed(11); feed(4)
        }
        return m
    }

    static func event(_ column: Int, for m: RecorderStateMachine) -> RecorderEvent {
        switch column {
        case 1: return .deviceConnected(deviceA, autoStartEntryID: "eA")
        case 2: return .deviceConnected(deviceB, autoStartEntryID: "eB")
        case 3: return .deviceConnected(deviceU, autoStartEntryID: nil)
        case 4: return .deviceDisconnected(deviceA)
        case 5: return .deviceDisconnected(deviceB)
        case 6: return .timerFired(token: m.pendingTimerToken ?? 1)
        case 7: return .timerFired(token: 99)
        case 8: return .cancelCountdown
        case 9: return .manualStart
        case 10: return .manualStop
        case 11: return .pause
        case 12: return .resume
        case 13: return .startForConnectedDevice(deviceA, entryID: "eA")
        default: return .sessionEnded
        }
    }

    private struct Change {
        var to: Config
        var origin: DeviceIdentity?? = .none   // .none = take the destination configuration's origin
        var effects: [RecorderEffect]
    }

    private static let N5A = RecorderEffect.postCountdownNotice(deviceA, seconds: 5)
    private static let N5B = RecorderEffect.postCountdownNotice(deviceB, seconds: 5)
    private static let D = RecorderEffect.dismissCountdownNotice
    private static let T5 = RecorderEffect.scheduleTimer(seconds: 5, token: 1)
    private static let T30 = RecorderEffect.scheduleTimer(seconds: 30, token: 2)
    private static let X = RecorderEffect.cancelTimer
    private static let SA = RecorderEffect.startRecording(.device(deviceA), .auto)
    private static let SM = RecorderEffect.startRecording(.systemDefault, .manual)
    private static let P = RecorderEffect.pauseRecording
    private static let R = RecorderEffect.resumeRecording
    private static let Q = RecorderEffect.stopRecording
    private static let Mminus = RecorderEffect.suspendMicrophone
    private static let Mplus = RecorderEffect.reattachMicrophone(deviceA)
    private static let G30 = RecorderEffect.showGraceBanner(seconds: 30)
    private static let g = RecorderEffect.clearGraceBanner

    private static let overrides: [Config: [Int: Change]] = [
        .I: [1: Change(to: .CD, effects: [N5A, T5]),
             2: Change(to: .CD, origin: .some(deviceB), effects: [N5B, T5]),
             9: Change(to: .RM, effects: [SM]),
             13: Change(to: .RA, effects: [SA])],
        .CD: [4: Change(to: .I, effects: [X, D]),
              6: Change(to: .RA, effects: [D, SA]),
              8: Change(to: .I, effects: [X, D]),
              9: Change(to: .RM, effects: [X, D, SM])],
        .RA: [4: Change(to: .GR, effects: [Mminus, T30, G30]),
              10: Change(to: .I, effects: [Q]),
              11: Change(to: .PA, effects: [P]),
              14: Change(to: .I, effects: [])],
        .RM: [10: Change(to: .I, effects: [Q]),
              11: Change(to: .PM, effects: [P]),
              14: Change(to: .I, effects: [])],
        .PA: [4: Change(to: .GP, effects: [Mminus, T30, G30]),
              10: Change(to: .I, effects: [Q]),
              12: Change(to: .RA, effects: [R]),
              14: Change(to: .I, effects: [])],
        .PM: [10: Change(to: .I, effects: [Q]),
              12: Change(to: .RM, effects: [R]),
              14: Change(to: .I, effects: [])],
        .GR: [1: Change(to: .RA, effects: [X, g, Mplus]),
              6: Change(to: .I, effects: [g, Q]),
              10: Change(to: .I, effects: [X, g, Q]),
              14: Change(to: .I, effects: [X, g])],
        // Y7b: reattach returns to paused and does not resume; the user's resume waits for the device.
        .GP: [1: Change(to: .PA, effects: [X, g, Mplus]),
              6: Change(to: .I, effects: [g, Q]),
              10: Change(to: .I, effects: [X, g, Q]),
              14: Change(to: .I, effects: [X, g])],
    ]

    static let cells: [Cell] = Config.allCases.flatMap { from in
        (1...14).map { column -> Cell in
            guard let change = overrides[from]?[column] else {
                return Cell(from: from, column: column, to: snapshot(of: from), effects: [])
            }
            var to = snapshot(of: change.to)
            if let origin = change.origin { to.origin = origin }
            return Cell(from: from, column: column, to: to, effects: change.effects)
        }
    }
}
