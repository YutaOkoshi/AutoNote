import Foundation
import CoreAudio
import AutoNoteCore

/// Records `TapHardware` calls and lets a test invoke the registered IOProc block with synthetic input.
public final class FakeTapHardware: TapHardware, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _lastTapSpec: TapSpec?
    private var _failOn: String?
    private var _teardownDelay: Duration = .zero
    private var _format: AudioStreamBasicDescription
    private var block: AudioDeviceIOBlock?

    public static let tapID: AudioObjectID = 101
    public static let aggregateID: AudioObjectID = 202
    public static let tapUUID = "00000000-0000-0000-0000-00000000FA4E"
    private static let procID: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }

    public init() {
        let channels: UInt32 = 2
        _format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    public var calls: [String] { lock.withLock { _calls } }
    public var lastTapSpec: TapSpec? { lock.withLock { _lastTapSpec } }
    /// Name of the call (as recorded in `calls`) that throws `AudioSourceError.coreAudio`.
    public var failOn: String? {
        get { lock.withLock { _failOn } }
        set { lock.withLock { _failOn = newValue } }
    }
    /// Blocks the calling thread for this long inside `stop` and each `destroy*` call.
    public var teardownDelay: Duration {
        get { lock.withLock { _teardownDelay } }
        set { lock.withLock { _teardownDelay = newValue } }
    }
    /// Default: 48 kHz / 2 ch / Float32 interleaved.
    public var format: AudioStreamBasicDescription {
        get { lock.withLock { _format } }
        set { lock.withLock { _format = newValue } }
    }

    private func record(_ name: String, teardown: Bool = false) throws {
        let (fail, delay) = lock.withLock { () -> (Bool, Duration) in
            _calls.append(name)
            return (_failOn == name, _teardownDelay)
        }
        if teardown, delay > .zero {
            let c = delay.components
            Thread.sleep(forTimeInterval: Double(c.seconds) + Double(c.attoseconds) / 1e18)
        }
        if fail { throw AudioSourceError.coreAudio(call: name, status: -1) }
    }

    public func createTap(_ spec: TapSpec) throws -> (id: AudioObjectID, uuid: String) {
        lock.withLock { _lastTapSpec = spec }
        try record("createTap")
        return (Self.tapID, Self.tapUUID)
    }

    public func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try record("tapFormat")
        return format
    }

    public func defaultOutputDeviceUID() throws -> String {
        try record("defaultOutputDeviceUID")
        return "FakeOutputDevice"
    }

    public func createAggregate(_ description: [String: any Sendable]) throws -> AudioObjectID {
        try record("createAggregate")
        return Self.aggregateID
    }

    public func createIOProc(_ device: AudioObjectID, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID {
        try record("createIOProc")
        lock.withLock { self.block = block }
        return Self.procID
    }

    public func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws { try record("start") }
    public func stop(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws { try record("stop", teardown: true) }
    public func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws {
        try record("destroyIOProc", teardown: true)
        lock.withLock { block = nil }
    }
    public func destroyAggregate(_ device: AudioObjectID) throws { try record("destroyAggregate", teardown: true) }
    public func destroyTap(_ tap: AudioObjectID) throws { try record("destroyTap", teardown: true) }

    /// Calls the registered IOProc block synchronously with `frames` interleaved Float32 frames all equal to `value`.
    /// Does nothing when no block is registered.
    public func fire(frames: Int, hostTime: UInt64, sampleTime: Double, value: Float) {
        guard let block = lock.withLock({ self.block }) else { return }
        let channels = Int(format.mChannelsPerFrame)
        var samples = [Float](repeating: value, count: frames * channels)
        var time = AudioTimeStamp()
        time.mHostTime = hostTime
        time.mSampleTime = sampleTime
        time.mFlags = [.hostTimeValid, .sampleTimeValid]
        var output = AudioBufferList()
        samples.withUnsafeMutableBytes { raw in
            var input = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            block(&time, &input, &time, &output, &time)
        }
    }
}
