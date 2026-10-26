import Foundation
import AutoNoteCore

/// Records every call. Attach failures are scripted per UID; `emitSelfStop()` plays a stop the recorder made itself.
public actor FakeRecordingControl: RecordingControl {
    public private(set) var starts: [(DeviceRef?, Language, Bool)] = []
    public private(set) var stopReasons: [StopReason] = []
    public private(set) var pauseCount = 0
    public private(set) var resumeCount = 0
    public private(set) var bookmarks: [String?] = []
    public private(set) var languages: [Language] = []
    public private(set) var detachCount = 0
    public private(set) var attachCalls: [String?] = []

    public var stopCount: Int { stopReasons.count }

    private var attachFailures: [String: (remaining: Int, error: any Error)] = [:]
    private var defaultAttachError: (any Error)?
    private var startFails = false
    private var selfStopStream: AsyncStream<Void>?
    private var selfStopContinuation: AsyncStream<Void>.Continuation?

    public init() {}

    /// The next `times` attaches to `uid` throw `error`.
    public func failAttach(uid: String, times: Int,
                           error: any Error = AudioSourceError.deviceNotFound(uid: "fake")) {
        attachFailures[uid] = (times, error)
    }

    /// Every attach to the default input (`uid: nil`) throws `error`.
    public func failDefaultAttach(error: any Error = AudioSourceError.deviceNotFound(uid: "default")) {
        defaultAttachError = error
    }

    /// Every later `start` throws `RecordingError.allSourcesFailed("fake")`.
    public func failStart() { startFails = true }

    public func emitSelfStop() {
        _ = ensureSelfStopStream()
        selfStopContinuation?.yield(())
    }

    public func start(device: DeviceRef?, language: Language, manual: Bool) async throws -> MeetingID {
        starts.append((device, language, manual))
        if startFails { throw RecordingError.allSourcesFailed("fake") }
        return MeetingID(rawValue: "fake-meeting-\(starts.count)")
    }

    public func stop(reason: StopReason) async { stopReasons.append(reason) }
    public func pause() async { pauseCount += 1 }
    public func resume() async { resumeCount += 1 }

    public func bookmark(note: String?) async throws -> Bookmark {
        bookmarks.append(note)
        return Bookmark(at: .zero, note: note)
    }

    public func setLanguage(_ language: Language) async { languages.append(language) }
    public func detachMicrophone() async { detachCount += 1 }

    public func attachMicrophone(uid: String?) async throws {
        attachCalls.append(uid)
        guard let uid else {
            if let defaultAttachError { throw defaultAttachError }
            return
        }
        if let failure = attachFailures[uid], failure.remaining > 0 {
            attachFailures[uid] = (failure.remaining - 1, failure.error)
            throw failure.error
        }
    }

    /// Always the same stream (single consumer).
    public func selfStops() async -> AsyncStream<Void> { ensureSelfStopStream() }

    private func ensureSelfStopStream() -> AsyncStream<Void> {
        if let selfStopStream { return selfStopStream }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        selfStopStream = stream; selfStopContinuation = continuation
        return stream
    }
}
