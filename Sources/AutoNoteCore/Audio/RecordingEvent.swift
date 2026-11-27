import Foundation

public enum StopReason: String, Sendable, Equatable { case manual, deviceGone, diskFull, appTerminating }

public enum SessionState: Sendable, Equatable { case idle, recording(MeetingID), paused(MeetingID) }

public struct TrackStatistics: Sendable, Equatable {
    public var chunks: Int
    public var samples: Int
    public var peakDBFS: Double

    public init(chunks: Int = 0, samples: Int = 0, peakDBFS: Double = -.infinity) {
        self.chunks = chunks; self.samples = samples; self.peakDBFS = peakDBFS
    }
}

public enum RecordingError: Error, Equatable, Sendable {
    case alreadyRecording, notRecording, notPaused, alreadyPaused
    case microphonePermission(MicrophonePermissionStatus)
    case insufficientDiskSpace(availableBytes: Int64)
    case allSourcesFailed(String)
}

/// What a `RecordingSession` tells its subscribers (`RecordingSession.events()`).
public enum RecordingEvent: Sendable, Equatable {
    case started(MeetingID)
    case paused(TimelineTime)
    case resumed(TimelineTime)
    case bookmarked(Bookmark)
    case silenceWarning(SilenceWarning)
    case diskSpaceLow(availableBytes: Int64)
    case sourceFailed(Track, message: String)
    /// A track `sourceFailed` was sent for is being recorded again (the microphone was attached again, or the system
    /// tap that was given up on is heard). Not sent after a writer's failure: that track stays lost.
    case sourceRecovered(Track)
    /// Audio that should be arriving on `track` has not for `seconds` although the source was rebuilt (system audio:
    /// another app plays, yet only zeros arrive). Sent once per such stretch; the recording goes on.
    /// `heardBefore` false: the track has not delivered one non-zero sample in this recording, so the permission to
    /// record it is in doubt too.
    case audioNotArriving(Track, seconds: Int, heardBefore: Bool)
    /// Audio is heard again on a track that `audioNotArriving` was sent for.
    case audioArrivingAgain(Track)
    case microphoneDetached(TimelineTime)
    case microphoneAttached(TimelineTime, device: DeviceRef?)
    case stopped(Manifest, StopReason)
}
