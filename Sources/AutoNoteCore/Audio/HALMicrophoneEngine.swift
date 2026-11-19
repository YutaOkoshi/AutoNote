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

    public init() {}

    public var isRunning: Bool {
        guard running, let device else { return false }
        return CoreAudioHardware.uint32Prop(device, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? false
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
        if let device { removeListeners(device) }
        device = nil
        format = nil
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
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              Int(size) / MemoryLayout<AudioStreamID>.size == 1 else { return nil }
        var stream = AudioStreamID(0)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &stream) == noErr else { return nil }
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &asbdSize, &asbd) == noErr,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, asbd.mBitsPerChannel == 32,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return InputFormat(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
    }

    /// Rate, stream layout and liveness changes reach the source as configuration changes.
    private func addListeners(_ device: AudioObjectID) {
        let handler = self.handler
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler.value.withLock { $0 }?() }
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        ]
        for (selector, scope) in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr {
                listeners.append(Listener(address: address, block: block))
            }
        }
    }

    private func removeListeners(_ device: AudioObjectID) {
        for var l in listeners { AudioObjectRemovePropertyListenerBlock(device, &l.address, listenerQueue, l.block) }
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
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "MicrophoneSource")

    public init(av: any MicrophoneEngine = AVMicrophoneEngine(), hal: any MicrophoneEngine = HALMicrophoneEngine(),
                usesHAL: @escaping @Sendable (AudioDeviceID?, Bool) -> Bool = RoutingMicrophoneEngine.bluetoothWithoutVoiceProcessing) {
        self.av = av; self.hal = hal; self.usesHAL = usesHAL
    }

    public static let bluetoothWithoutVoiceProcessing: @Sendable (AudioDeviceID?, Bool) -> Bool = { deviceID, voiceProcessing in
        guard !voiceProcessing,
              let id = deviceID ?? AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
              CoreAudioHardware.uint32Prop(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth else { return false }
        return HALMicrophoneEngine.inputFormat(id) != nil
    }

    public var isRunning: Bool { active?.isRunning ?? false }
    public func currentFormat() -> InputFormat? { active?.currentFormat() }
    public func routeDescription() -> String { (active ?? av).routeDescription() }

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
        return try engine.prepare(deviceID: deviceID, voiceProcessing: voiceProcessing)
    }

    public func start(writingTo ring: AudioRingBuffer) throws {
        guard let active else { throw AudioSourceError.unsupportedFormat }
        try active.start(writingTo: ring)
    }

    public func stop() { active?.stop() }
}
