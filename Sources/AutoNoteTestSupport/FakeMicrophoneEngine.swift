import Foundation
import CoreAudio
import AutoNoteCore

/// Records `prepare` and lets a test write synthetic input into the ring handed to `start(writingTo:)`.
/// It can also play the Bluetooth A2DP→HFP switch: stop itself right after `start` and post a configuration change,
/// change its hardware format, or simply never deliver callbacks (push nothing).
public final class FakeMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _prepared: (deviceID: AudioDeviceID?, voiceProcessing: Bool)?
    private var _prepareCount = 0
    private var _startCount = 0
    private var _format = InputFormat(sampleRate: 48_000, channels: 1)
    private var _stopDelay: Duration = .zero
    private var _isStopped = false
    private var _isRunning = false
    private var _stopItselfOnStarts = 0
    private var _notificationDelay = 0.003
    private var _prepareError: (any Error)?
    private var _prepareErrorsLeft = 0
    private var handler: (@Sendable () -> Void)?
    private var ring: AudioRingBuffer?

    public init() {}

    /// Arguments of the last `prepare`; nil until it is called.
    public var prepared: (deviceID: AudioDeviceID?, voiceProcessing: Bool)? { lock.withLock { _prepared } }
    public var prepareCount: Int { lock.withLock { _prepareCount } }
    /// Successful `start` calls so far.
    public var startCount: Int { lock.withLock { _startCount } }
    /// True after `stop` returns.
    public var isStopped: Bool { lock.withLock { _isStopped } }
    public var isRunning: Bool { lock.withLock { _isRunning } }
    /// The hardware format: returned by `prepare` and `currentFormat`. Default: 48 kHz / 1 ch.
    public var format: InputFormat {
        get { lock.withLock { _format } }
        set { lock.withLock { _format = newValue } }
    }
    /// Blocks the calling thread for this long inside `stop`.
    public var stopDelay: Duration {
        get { lock.withLock { _stopDelay } }
        set { lock.withLock { _stopDelay = newValue } }
    }
    /// The next this-many `start`s succeed, then the engine stops itself at once and posts a configuration change
    /// (what `AVAudioEngine` does on `iounit configuration changed > stopping the engine`).
    public var stopItselfOnStarts: Int {
        get { lock.withLock { _stopItselfOnStarts } }
        set { lock.withLock { _stopItselfOnStarts = newValue } }
    }

    /// Seconds between stopping itself and posting the configuration change (default 3 ms, as observed).
    public var notificationDelay: Double {
        get { lock.withLock { _notificationDelay } }
        set { lock.withLock { _notificationDelay = newValue } }
    }

    /// The next `count` `prepare` calls throw `error`.
    public func failPrepare(_ count: Int, with error: any Error) {
        lock.withLock { _prepareErrorsLeft = count; _prepareError = error }
    }

    public func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat {
        try lock.withLock {
            _prepared = (deviceID, voiceProcessing)
            _prepareCount += 1
            if _prepareErrorsLeft > 0, let error = _prepareError {
                _prepareErrorsLeft -= 1
                throw error
            }
            _isStopped = false
            return _format
        }
    }

    public func start(writingTo ring: AudioRingBuffer) throws {
        let stopsItself = lock.withLock { () -> Bool in
            _startCount += 1
            if _stopItselfOnStarts > 0 {
                _stopItselfOnStarts -= 1
                return true
            }
            self.ring = ring
            _isRunning = true
            return false
        }
        if stopsItself {
            let (handler, delay) = lock.withLock { (self.handler, _notificationDelay) }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { handler?() }
        }
    }

    public func stop() {
        let delay = lock.withLock { _stopDelay }
        if delay > .zero {
            let c = delay.components
            Thread.sleep(forTimeInterval: Double(c.seconds) + Double(c.attoseconds) / 1e18)
        }
        lock.withLock { ring = nil; _isStopped = true; _isRunning = false }
    }

    public func currentFormat() -> InputFormat? { lock.withLock { _format } }

    public func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    /// Posts a configuration change. With `stopEngine`, the engine stops first (no more input reaches the ring);
    /// `newFormat` becomes the hardware format.
    public func simulateConfigurationChange(stopEngine: Bool, newFormat: InputFormat? = nil) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            if let newFormat { _format = newFormat }
            if stopEngine { ring = nil; _isRunning = false }
            return self.handler
        }
        handler?()
    }

    /// Writes `frames` interleaved Float32 frames of `format.channels` channels, all equal to `value`, into the ring
    /// synchronously on the caller's thread. Does nothing before `start`, after `stop` or once the engine stopped itself.
    public func push(frames: Int, hostTime: UInt64, value: Float) {
        let (ring, channels) = lock.withLock { (self.ring, _format.channels) }
        guard let ring, frames > 0 else { return }
        var samples = [Float](repeating: value, count: frames * channels)
        samples.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            ring.write(&abl, frameCount: frames, hostTime: hostTime, sampleTime: 0)
        }
    }
}

public struct FakeMicrophonePermission: MicrophonePermissionChecking {
    public var current: MicrophonePermissionStatus

    public init(_ status: MicrophonePermissionStatus) { self.current = status }
    public init(status: MicrophonePermissionStatus) { self.current = status }

    public func status() -> MicrophonePermissionStatus { current }
}

/// Resolves only the UIDs in `devices`; `deviceRef(forUID: nil)` is a fixed built-in default input.
public struct FakeDeviceLookup: AudioDeviceLookup {
    public var devices: [String: AudioDeviceID]

    public init(devices: [String: AudioDeviceID] = [:]) { self.devices = devices }

    public func deviceID(forUID uid: String) -> AudioDeviceID? { devices[uid] }

    public func deviceRef(forUID uid: String?) -> DeviceRef? {
        guard let uid else { return DeviceRef(name: "Default", uid: "default", transport: "builtin") }
        return devices[uid] == nil ? nil : DeviceRef(name: uid, uid: uid, transport: "unknown")
    }
}
