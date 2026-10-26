import Foundation
import os

/// What the device coordinator (Task 8) needs from the recorder. `RecordingSessionControl` adapts plan 02's
/// `RecordingSession`; tests use `FakeRecordingControl`.
public protocol RecordingControl: Sendable {
    func start(device: DeviceRef?, language: Language, manual: Bool) async throws -> MeetingID
    func stop(reason: StopReason) async
    func pause() async
    func resume() async
    func bookmark(note: String?) async throws -> Bookmark
    func setLanguage(_ language: Language) async
    func detachMicrophone() async
    func attachMicrophone(uid: String?) async throws
    /// Stops the recorder made on its own (disk full and the like), not the ones asked for with `stop(reason:)`.
    /// `async` so the subscription exists before the call returns: no stop after it is missed.
    func selfStops() async -> AsyncStream<Void>
}

/// Thin adapter over `RecordingSession`. Errors of the non-throwing operations are logged and swallowed.
public actor RecordingSessionControl: RecordingControl {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "RecordingControl")

    private let session: RecordingSession
    /// Set by `stop(reason:)` while its `.stopped` event has not been seen yet. Holding the reason (not just a flag)
    /// keeps a self-stop with a different reason that lands during our own stop from being swallowed.
    private var expectingOwnStop: StopReason?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var forwarding: Task<Void, Never>?

    public init(session: RecordingSession) { self.session = session }

    public func start(device: DeviceRef?, language: Language, manual: Bool) async throws -> MeetingID {
        try await session.start(.init(language: language, microphoneUID: device?.uid, device: device))
    }

    public func stop(reason: StopReason) async {
        expectingOwnStop = reason
        do {
            _ = try await session.stop(reason: reason)
        } catch {
            expectingOwnStop = nil
            Self.log("stop", error)
        }
    }

    public func pause() async {
        do { try await session.pause() } catch { Self.log("pause", error) }
    }

    public func resume() async {
        do { try await session.resume() } catch { Self.log("resume", error) }
    }

    public func bookmark(note: String?) async throws -> Bookmark {
        try await session.bookmark(note: note)
    }

    public func setLanguage(_ language: Language) async {
        do { try await session.setLanguage(language) } catch { Self.log("setLanguage", error) }
    }

    public func detachMicrophone() async {
        do { try await session.detachMicrophone() } catch { Self.log("detachMicrophone", error) }
    }

    public func attachMicrophone(uid: String?) async throws {
        try await session.attachMicrophone(deviceUID: uid)
    }

    /// Every call gets its own stream; all of them see the same self-stops from then on.
    public func selfStops() async -> AsyncStream<Void> {
        if forwarding == nil {
            let events = await session.events()
            if forwarding == nil {   // re-check: another call may have subscribed during the await
                forwarding = Task { [weak self] in
                    for await event in events {
                        guard let self else { return }
                        await self.handle(event)
                    }
                }
            }
        }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        subscribers[id] = continuation
        return stream
    }

    private func handle(_ event: RecordingEvent) {
        guard case .stopped(_, let reason) = event else { return }
        if let expected = expectingOwnStop, expected == reason {
            expectingOwnStop = nil
            return
        }
        for continuation in subscribers.values { continuation.yield(()) }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private static func log(_ what: String, _ error: any Error) {
        logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}

public enum ReattachOutcome: Equatable, Sendable {
    case device(attempts: Int)
    case fallbackToDefault
    case failed
}

/// Re-attaches the microphone after its device comes back (provisional method; spike item 10 not done yet).
/// Right after the device returns its input stream may not be ready, so `attachMicrophone(uid:)` is tried every
/// `retryInterval` seconds up to `maxAttempts` times; then the Mac's default input (`uid: nil`, spec §11.5).
/// If that fails too the outcome is `.failed`: the mic track stays silent and the recording goes on.
public struct MicrophoneReattacher: Sendable {
    let control: any RecordingControl
    let timer: any TimerScheduling
    let retryInterval: Double
    let maxAttempts: Int

    public init(control: any RecordingControl, timer: any TimerScheduling, retryInterval: Double = 0.5,
                maxAttempts: Int = 20) {
        self.control = control; self.timer = timer; self.retryInterval = retryInterval; self.maxAttempts = maxAttempts
    }

    /// Never throws. A cancelled reattach returns `.failed` (the caller ignores it).
    public func reattach(uid: String) async -> ReattachOutcome {
        for attempt in 1...max(1, maxAttempts) {
            if attempt > 1 {
                do { try await timer.sleep(seconds: retryInterval) } catch { return .failed }
            }
            if Task.isCancelled { return .failed }
            do {
                try await control.attachMicrophone(uid: uid)
                return .device(attempts: attempt)
            } catch {
                guard Self.isRetryable(error) else { return .failed }
            }
        }
        if Task.isCancelled { return .failed }
        do {
            try await control.attachMicrophone(uid: nil)
            return .fallbackToDefault
        } catch {
            return .failed
        }
    }

    /// The device may still be coming up: not found yet, a Core Audio error, or a call that timed out.
    /// Anything else (permission, no recording, unknown errors) will not get better by waiting.
    static func isRetryable(_ error: any Error) -> Bool {
        switch error as? AudioSourceError {
        case .deviceNotFound, .coreAudio, .timedOut: true
        default: false
        }
    }
}
