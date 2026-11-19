import Foundation
import CoreAudio
import Synchronization
import os

/// Microphone input straight from the device's HAL IOProc, without `AVAudioEngine`.
///
/// Why: with a Bluetooth headset, `AVAudioEngine` sets the headset's Bluetooth audio format itself while it prepares
/// and starts (`SetBluetoothAudioFormat…`). On the real headset that flips the headset between A2DP and HFP, stops the
/// engine (`iounit configuration changed > stopping the engine`), and with the input already on HFP it waits 3 s twice
/// (`Waiting for format change timed out`) before it starts. A plain IOProc on the input device does none of this:
/// opening it switches the headset to HFP once and the IO keeps running.
/// Used for Bluetooth inputs without voice processing (see `RoutingMicrophoneEngine`).
public final class HALMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {   // mutated only on the source's control queue
    private final class HandlerBox: Sendable {
        let value = Mutex<(@Sendable () -> Void)?>(nil)
    }

    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private let handler = HandlerBox()
    private let ioQueue = DispatchQueue(label: "com.yutaokoshi.autonote.mic.hal", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.yutaokoshi.autonote.mic.hal.listen")
    private var device: AudioObjectID?
    private var format: InputFormat?
    private var proc: AudioDeviceIOProcID?
    private var listeners: [Listener] = []
    private var running = false
    /// Prepared with `deviceID == nil`: the graph reads whatever the default input was then, and must follow it.
    private var followsDefault = false

    public init() {}

    public var isRunning: Bool {
        guard running, let device else { return false }
        return CoreAudioHardware.uint32Prop(device, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? false
    }

    /// The default input moved away from the device a default-following graph reads, or the device died.
    public var needsRebuild: Bool {
        guard let device else { return false }
        let alive = CoreAudioHardware.uint32Prop(device, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? false
        return Self.isStale(followsDefault: followsDefault, device: device,
                            defaultInput: AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice), alive: alive)
    }

    static func isStale(followsDefault: Bool, device: AudioObjectID, defaultInput: AudioObjectID?, alive: Bool) -> Bool {
        if !alive { return true }
        guard followsDefault, let defaultInput else { return false }
        return defaultInput != device
    }

    public func currentFormat() -> InputFormat? {
        guard let device else { return nil }
        return Self.inputFormat(device)
    }

    public func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        self.handler.value.withLock { $0 = handler }
    }

    public func routeDescription() -> String { AudioRoute.describeDefaults() }

    /// The device (nil = default input) and its input format: one Float32 stream, so the IOProc buffer is interleaved.
    public func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat {
        stop()
        guard let id = deviceID ?? AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else {
            throw AudioSourceError.deviceNotFound(uid: "default input")
        }
        guard let fmt = Self.inputFormat(id) else { throw AudioSourceError.unsupportedFormat }
        device = id
        format = fmt
        followsDefault = deviceID == nil
        addListeners(id)
        return fmt
    }

    public func start(writingTo ring: AudioRingBuffer) throws {
        guard let device, format != nil else { throw AudioSourceError.unsupportedFormat }
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue, Self.makeIOBlock(ring: ring))
        guard status == noErr, let procID else {
            throw AudioSourceError.coreAudio(call: "AudioDeviceCreateIOProcIDWithBlock", status: status)
        }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            throw AudioSourceError.coreAudio(call: "AudioDeviceStart", status: status)
        }
        proc = procID
        running = true
    }

    public func stop() {
        if let device, let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        running = false
        removeListeners()
        device = nil
        format = nil
        followsDefault = false
    }

    /// The real-time body: copy into the ring and nothing else.
    nonisolated static func makeIOBlock(ring: AudioRingBuffer) -> AudioDeviceIOBlock {
        { _, input, inputTime, _, _ in
            let time = inputTime.pointee
            guard time.mFlags.contains(.hostTimeValid), time.mHostTime != 0 else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mNumberChannels > 0 else { return }
            let frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
            _ = ring.write(input, frameCount: frames, hostTime: time.mHostTime, sampleTime: time.mSampleTime)
        }
    }

    /// Nominal rate and channel count of the device's single input stream, when it is Float32.
    static func inputFormat(_ device: AudioObjectID) -> InputFormat? {
        guard let (count, asbd) = streamDescription(device) else { return nil }
        return inputFormat(streamCount: count, asbd: asbd)
    }

    /// One interleaved Float32 linear PCM stream: what `AudioRingBuffer` takes as one buffer.
    static func inputFormat(streamCount: Int, asbd: AudioStreamBasicDescription) -> InputFormat? {
        guard streamCount == 1, asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 || asbd.mChannelsPerFrame == 1,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return InputFormat(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
    }

    /// Input stream count and the first stream's virtual format.
    private static func streamDescription(_ device: AudioObjectID) -> (Int, AudioStreamBasicDescription)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count >= 1 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        let stream = streams[0]
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &asbdSize, &asbd) == noErr else { return nil }
        return (count, asbd)
    }

    /// Rate, stream layout and liveness changes reach the source as configuration changes; so does a new default
    /// input when the graph follows the default (then `needsRebuild` tells the source to move).
    private func addListeners(_ device: AudioObjectID) {
        let handler = self.handler
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler.value.withLock { $0 }?() }
        var targets: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        ]
        if followsDefault {
            targets.append((AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal))
        }
        for (object, selector, scope) in targets {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
                listeners.append(Listener(object: object, address: address, block: block))
            }
        }
    }

    private func removeListeners() {
        for var l in listeners { AudioObjectRemovePropertyListenerBlock(l.object, &l.address, listenerQueue, l.block) }
        listeners = []
    }
}

/// Picks the engine per `prepare`: `HALMicrophoneEngine` for a Bluetooth input without voice processing (whose
/// single input stream is Float32), `AVMicrophoneEngine` otherwise. The configuration change handler reaches both.
public final class RoutingMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {   // mutated only on the control queue
    private let av: any MicrophoneEngine
    private let hal: any MicrophoneEngine
    private let usesHAL: @Sendable (AudioDeviceID?, Bool) -> Bool
    private var active: (any MicrophoneEngine)?
    private let defaultInput: @Sendable () -> AudioObjectID?
    /// The default input at `prepare(deviceID: nil)`; nil when prepared for a fixed device.
    private var preparedDefault: AudioObjectID?
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "MicrophoneSource")

    public init(av: any MicrophoneEngine = AVMicrophoneEngine(), hal: any MicrophoneEngine = HALMicrophoneEngine(),
                usesHAL: @escaping @Sendable (AudioDeviceID?, Bool) -> Bool = RoutingMicrophoneEngine.bluetoothWithoutVoiceProcessing,
                defaultInput: (@Sendable () -> AudioObjectID?)? = nil) {
        self.av = av; self.hal = hal; self.usesHAL = usesHAL
        self.defaultInput = defaultInput ?? { AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    }

    public static let bluetoothWithoutVoiceProcessing: @Sendable (AudioDeviceID?, Bool) -> Bool = { deviceID, voiceProcessing in
        guard !voiceProcessing, let id = deviceID ?? AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return false }
        return choosesHAL(transportType: CoreAudioHardware.uint32Prop(id, kAudioDevicePropertyTransportType), voiceProcessing: false,
                          singleFloat32Stream: HALMicrophoneEngine.inputFormat(id) != nil)
    }

    /// Bluetooth classic or LE (as `CoreAudioHardware.transport` counts them), no voice processing, a stream the HAL
    /// engine can read.
    static func choosesHAL(transportType: UInt32?, voiceProcessing: Bool, singleFloat32Stream: Bool) -> Bool {
        !voiceProcessing && singleFloat32Stream && CoreAudioHardware.transport(coreAudio: transportType) == .bluetooth
    }

    // Read on the source's control queue only (like `prepare`, which replaces `active`).
    public var isRunning: Bool { active?.isRunning ?? false }
    public func currentFormat() -> InputFormat? { active?.currentFormat() }
    /// Prepared for the default input and the default moved (whichever engine runs: the new default may need the other
    /// one), or the active engine says so.
    public var needsRebuild: Bool {
        if let preparedDefault, let now = defaultInput(), now != preparedDefault { return true }
        return active?.needsRebuild ?? false
    }
    /// Called from the source's actor, off the control queue: must not read `active`. Both engines describe the
    /// default route the same way.
    public func routeDescription() -> String { AudioRoute.describeDefaults() }

    public func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        av.setConfigurationChangeHandler(handler)
        hal.setConfigurationChangeHandler(handler)
    }

    public func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat {
        active?.stop()
        let engine = usesHAL(deviceID, voiceProcessing) ? hal : av
        if active !== engine {
            Self.logger.notice("mic engine: \(engine === self.hal ? "HAL IOProc (bluetooth input)" : "AVAudioEngine", privacy: .public)")
        }
        active = engine
        preparedDefault = deviceID == nil ? defaultInput() : nil
        return try engine.prepare(deviceID: deviceID, voiceProcessing: voiceProcessing)
    }

    public func start(writingTo ring: AudioRingBuffer) throws {
        guard let active else { throw AudioSourceError.unsupportedFormat }
        try active.start(writingTo: ring)
    }

    public func stop() { active?.stop() }
}
