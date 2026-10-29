import Foundation

/// What the queue looks like right now; `NoticeRelay` reads it.
public struct QueueSnapshot: Equatable, Sendable {
    /// `(createdAt, id)` ascending. Done jobs appear only when they carry a `summaryFailure`.
    public var jobs: [JobProgress]
    public var pausedForRecording: Bool

    public init(jobs: [JobProgress], pausedForRecording: Bool) {
        self.jobs = jobs; self.pausedForRecording = pausedForRecording
    }
}

public struct JobProgress: Equatable, Sendable {
    public var meetingID: MeetingID
    /// The stage currently running, else the job's `nextStage`.
    public var stage: String?
    public var state: JobState
    /// In memory only; reported by the running stage.
    public var progress: Double?
    public var notBefore: Date?
    public var lastError: String?
    public var summaryFailure: SummaryFailureKind?
    /// Waiting for the user to decide whether an edited Vault file may be overwritten.
    public var awaitingConfirmation: Bool
    public var generation: Int

    public init(meetingID: MeetingID, stage: String?, state: JobState, progress: Double?, notBefore: Date?,
                lastError: String?, summaryFailure: SummaryFailureKind?, awaitingConfirmation: Bool, generation: Int) {
        self.meetingID = meetingID; self.stage = stage; self.state = state; self.progress = progress
        self.notBefore = notBefore; self.lastError = lastError; self.summaryFailure = summaryFailure
        self.awaitingConfirmation = awaitingConfirmation; self.generation = generation
    }
}
