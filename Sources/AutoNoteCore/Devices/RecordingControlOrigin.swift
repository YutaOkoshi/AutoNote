import Foundation

/// What made the recorder start, stop, pause or resume. `AutoRecordCoordinator` logs every event it applies with
/// one (`RecorderTransitionRecord`), so `log show` tells who ended a recording and why.
public enum RecordingControlOrigin: String, Sendable, Equatable, CaseIterable {
    // A person, by where they pressed it.
    /// A global shortcut (`HotKeyCenter`).
    case hotkey
    /// The menu bar menu.
    case menu
    /// The main window (its buttons and its notice bands).
    case window
    /// A button on a system notification.
    case notificationAction
    /// A command over the socket (`autonote start/stop/...`, also `autonote dev auto-record`).
    case cli

    // The app itself.
    /// The countdown after a registered device connected ran out.
    case countdownFired
    /// The grace period after the origin device left ran out.
    case graceExpired
    /// The recorder stopped itself because the disk is almost full.
    case diskFull
    /// The app is quitting.
    case terminating
    /// The recorder stopped itself for another reason.
    case sessionEnded
    /// The recorder's start threw, so the recording that was starting is over.
    case startFailed
    /// An input device was connected.
    case deviceConnected
    /// An input device was disconnected.
    case deviceDisconnected
    /// A settings save. No path starts or stops a recording on a save today; it is here so one never goes unlabelled.
    case settingsChanged

    /// The reason the recorder is told to stop with when this origin stops a recording.
    public var stopReason: StopReason {
        switch self {
        case .terminating: .appTerminating
        case .graceExpired: .deviceGone
        case .diskFull: .diskFull
        case .hotkey, .menu, .window, .notificationAction, .cli, .countdownFired, .sessionEnded, .startFailed,
             .deviceConnected, .deviceDisconnected, .settingsChanged: .manual
        }
    }
}

/// One event `AutoRecordCoordinator` applied, as it is logged. Tests receive it through `onTransition`.
public struct RecorderTransitionRecord: Sendable, Equatable {
    public var from: RecorderState
    public var to: RecorderState
    /// The `RecorderEvent` case name.
    public var event: String
    public var origin: RecordingControlOrigin
    /// The reason the recorder was told to stop with; nil when this event asked for no stop.
    public var stopReason: StopReason?
    /// The meeting being recorded when the event arrived.
    public var meetingID: MeetingID?

    public init(from: RecorderState, to: RecorderState, event: String, origin: RecordingControlOrigin,
                stopReason: StopReason?, meetingID: MeetingID?) {
        self.from = from; self.to = to; self.event = event; self.origin = origin
        self.stopReason = stopReason; self.meetingID = meetingID
    }

    /// "recording -> idle on manualStop (origin: hotkey, stop: manual, meeting: …)"; an event that changed nothing
    /// ends in " ignored".
    public var logLine: String {
        var details = ["origin: \(origin.rawValue)"]
        if let stopReason { details.append("stop: \(stopReason.rawValue)") }
        if let meetingID { details.append("meeting: \(meetingID.rawValue)") }
        let line = "\(from.rawValue) -> \(to.rawValue) on \(event) (\(details.joined(separator: ", ")))"
        return from == to ? line + " ignored" : line
    }
}
