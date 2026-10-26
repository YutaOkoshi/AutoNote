import Foundation

/// The outcome of one automation run (or of a skipped one). Written as `result.json` in the run's log folder.
public struct AutomationRunRecord: Codable, Equatable, Sendable {
    public var name: String
    public var event: AutomationTrigger
    public var meetingID: String
    public var startedAt: Date
    public var durationSeconds: Double
    /// `nil` when the command ended by a signal (including a timeout kill) or never started.
    public var exitCode: Int32?
    public var timedOut: Bool
    /// `"already_ran"` (dedupe ledger hit) or `"spawn_failed"`; `nil` when the command ran.
    public var skippedReason: String?
    /// Absolute path of the run's log folder; empty for an `already_ran` skip.
    public var logDirectory: String

    public var succeeded: Bool { skippedReason == nil && !timedOut && exitCode == 0 }

    public init(name: String, event: AutomationTrigger, meetingID: String, startedAt: Date, durationSeconds: Double,
                exitCode: Int32?, timedOut: Bool, skippedReason: String?, logDirectory: String) {
        self.name = name
        self.event = event
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.skippedReason = skippedReason
        self.logDirectory = logDirectory
    }

    // `meetingID` would snake-case to `meeting_i_d`; pin the key.
    private enum CodingKeys: String, CodingKey {
        case name, event, startedAt, durationSeconds, exitCode, timedOut, skippedReason, logDirectory
        case meetingID = "meetingId"
    }
}
