import Foundation
import CoreAudio
import AutoNoteCore

/// Records `prepare` and lets a test write synthetic input into the ring handed to `start(writingTo:)`.
public final class FakeMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _prepared: (deviceID: AudioDeviceID?, voiceProcessing: Bool)?
    private var _prepareCount = 0
    private var _format = InputFormat(sampleRate: 48_000, channels: 1)
    private var _stopDelay: Duration = .zero
    private var _isStopped = false
    private var ring: AudioRingBuffer?

    public init() {}

    /// Arguments of the last `prepare`; nil until it is called.
    public var prepared: (deviceID: AudioDeviceID?, voiceProcessing: Bool)? { lock.withLock { _prepared } }
    public var prepareCount: Int { lock.withLock { _prepareCount } }
    /// True after `stop` returns.
    public var isStopped: Bool { lock.withLock { _isStopped } }
    /// Returned by `prepare`. Default: 48 kHz / 1 ch.
    public var format: InputFormat {
        get { lock.withLock { _format } }
        set { lock.withLock { _format = newValue } }
    }
    /// Blocks the calling thread for this long inside `stop`.
    public var stopDelay: Duration {
        get { lock.withLock { _stopDelay } }
        set { lock.withLock { _stopDelay = newValue } }
    }

    public func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat {
        lock.withLock {
            _prepared = (deviceID, voiceProcessing)
            _prepareCount += 1
            _isStopped = false
            return _format
        }
    }

    public func start(writingTo ring: AudioRingBuffer) throws {
        lock.withLock { self.ring = ring }
    }

    public func stop() {
        let delay = lock.withLock { _stopDelay }
        if delay > .zero {
            let c = delay.components
            Thread.sleep(forTimeInterval: Double(c.seconds) + Double(c.attoseconds) / 1e18)
        }
        lock.withLock { ring = nil; _isStopped = true }
    }

    /// Writes `frames` interleaved Float32 frames of `format.channels` channels, all equal to `value`, into the ring
    /// synchronously on the caller's thread. Does nothing before `start` or after `stop`.
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
