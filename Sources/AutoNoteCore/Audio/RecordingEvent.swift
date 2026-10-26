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
    case microphoneDetached(TimelineTime)
    case microphoneAttached(TimelineTime, device: DeviceRef?)
    case stopped(Manifest, StopReason)
}
