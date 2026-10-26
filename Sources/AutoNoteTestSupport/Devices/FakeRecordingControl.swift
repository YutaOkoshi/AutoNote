import Foundation
import AutoNoteCore

/// Records every call. Attach failures are scripted per UID; `emitSelfStop()` plays a stop the recorder made itself.
/// `hold(_:)` makes the next calls of `start` / `detachMicrophone` block (after being recorded) until `release(_:)`.
public actor FakeRecordingControl: RecordingControl {
    public enum HeldCall: Hashable, Sendable { case start, detach }

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
    private var selfStopContinuations: [AsyncStream<Void>.Continuation] = []
    private var held: Set<HeldCall> = []
    private var blocked: [HeldCall: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func hold(_ call: HeldCall) { held.insert(call) }

    /// Stops holding `call` and lets every blocked call of it continue.
    public func release(_ call: HeldCall) {
        held.remove(call)
        blocked.removeValue(forKey: call)?.forEach { $0.resume() }
    }

    /// Number of calls of `call` currently blocked by `hold`.
    public func blockedCount(_ call: HeldCall) -> Int { blocked[call]?.count ?? 0 }

    private func pass(_ call: HeldCall) async {
        guard held.contains(call) else { return }
        await withCheckedContinuation { blocked[call, default: []].append($0) }
    }

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

    /// Yields once on every stream `selfStops()` has returned so far.
    public func emitSelfStop() {
        for continuation in selfStopContinuations { continuation.yield(()) }
    }

    public func start(device: DeviceRef?, language: Language, manual: Bool) async throws -> MeetingID {
        starts.append((device, language, manual))
        await pass(.start)
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
    public func detachMicrophone() async {
        detachCount += 1
        await pass(.detach)
    }

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

    /// A new stream per call; each gets every later `emitSelfStop()`.
    public func selfStops() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        selfStopContinuations.append(continuation)
        return stream
    }
}
