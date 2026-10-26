import Foundation
import CoreAudio
import os

/// Microphone input via `MicrophoneEngine` (production: `AVAudioEngine`), converted to 16 kHz mono chunks.
///
/// Refuses to touch the engine unless microphone access is already authorized. Engine calls run on a dedicated
/// serial queue; `stop` waits for `engine.stop()` at most `stopTimeout`.
public actor MicrophoneSource: AudioSource {
    public nonisolated let track: Track = .mic

    private enum State {
        case idle
        case starting
        case running(drain: Task<Void, Never>)
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "MicrophoneSource")

    private let deviceUID: String?
    private let clock: MeetingClock
    private let voiceProcessing: Bool
    private let permission: any MicrophonePermissionChecking
    private let engine: any MicrophoneEngine
    private let lookup: any AudioDeviceLookup
    private let stopTimeout: Duration
    private let controlQueue = DispatchQueue(label: "com.yutaokoshi.autonote.mic.control", qos: .userInitiated)

    private var state: State = .idle
    private var stopRequestedWhileStarting = false
    /// Test hook: whether the last `stop` gave up waiting for `engine.stop()`.
    private(set) var lastStopTimedOut = false

    public init(deviceUID: String?, clock: MeetingClock, voiceProcessing: Bool = false,
                permission: any MicrophonePermissionChecking = AVMicrophonePermission(),
                engine: any MicrophoneEngine = AVMicrophoneEngine(),
                lookup: any AudioDeviceLookup = CoreAudioDeviceLookup(),
                stopTimeout: Duration = .seconds(5)) {
        self.deviceUID = deviceUID; self.clock = clock; self.voiceProcessing = voiceProcessing
        self.permission = permission; self.engine = engine; self.lookup = lookup; self.stopTimeout = stopTimeout
    }

    /// Safety net when the owner drops a running source without `stop()`: no waiting, the engine stops in the background.
    deinit {
        if case .running(let drain) = state {
            drain.cancel()
            let engine = self.engine
            controlQueue.async { engine.stop() }
        }
    }

    /// permission → UID → `engine.prepare` → ring → drain task → `engine.start`.
    public func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws {
        guard case .idle = state else { throw AudioSourceError.alreadyStarted }
        let status = permission.status()
        guard status == .authorized else { throw AudioSourceError.microphonePermission(status) }
        let deviceID: AudioDeviceID?
        if let deviceUID {
            guard let id = lookup.deviceID(forUID: deviceUID) else { throw AudioSourceError.deviceNotFound(uid: deviceUID) }
            deviceID = id
        } else {
            deviceID = nil
        }
        state = .starting
        stopRequestedWhileStarting = false

        let engine = self.engine, voiceProcessing = self.voiceProcessing
        let format: InputFormat
        do {
            format = try await onControlQueue { try engine.prepare(deviceID: deviceID, voiceProcessing: voiceProcessing) }
        } catch {
            state = .idle
            throw error
        }
        guard format.channels > 0, format.sampleRate > 0,
              let converter = try? SampleConverter(inputSampleRate: format.sampleRate, inputChannels: format.channels) else {
            state = .idle
            await controlQueue.runAwaiting(timeout: stopTimeout) { engine.stop() }
            throw AudioSourceError.unsupportedFormat
        }
        let ring = AudioRingBuffer(channels: format.channels, capacityFrames: Int(format.sampleRate * 10), recordCapacity: 4096)
        let drain = SourceDrain.makeTask(track: track, ring: ring, converter: converter, inputRate: format.sampleRate,
                                         clock: clock, onBuffer: onBuffer)
        do {
            try await onControlQueue { try engine.start(writingTo: ring) }
        } catch {
            state = .idle
            await controlQueue.runAwaiting(timeout: stopTimeout) { engine.stop() }
            drain.cancel()
            await drain.value
            throw error
        }
        state = .running(drain: drain)
        if stopRequestedWhileStarting { await stop() }
    }

    /// `engine.stop()` on the control queue (bounded wait), then the drain task empties the ring and flushes.
    public func stop() async {
        switch state {
        case .idle: return
        case .starting: stopRequestedWhileStarting = true; return
        case .running(let drain):
            state = .idle
            let engine = self.engine
            let finished = await controlQueue.runAwaiting(timeout: stopTimeout) { engine.stop() }
            lastStopTimedOut = !finished
            if !finished { Self.logger.error("engine stop timeout") }
            drain.cancel()
            await drain.value
        }
    }

    private func onControlQueue<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        let queue = controlQueue
        return try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }
}
