import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization

public protocol MicrophonePermissionChecking: Sendable {
    func status() -> MicrophonePermissionStatus
}

/// Reads the current microphone authorization. Never requests it (the app's first-run flow does that).
public struct AVMicrophonePermission: MicrophonePermissionChecking {
    public init() {}

    public func status() -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }
}

public struct InputFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate; self.channels = channels
    }
}

/// Microphone hardware behind `MicrophoneSource`. Calls arrive on the source's serial control queue, never concurrently.
public protocol MicrophoneEngine: AnyObject, Sendable {
    /// Builds the input graph for `deviceID` (nil = system default input) and returns its native format.
    func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat
    /// Starts delivering Float32 input into `ring`.
    func start(writingTo ring: AudioRingBuffer) throws
    /// Tears the graph down; `prepare` builds a new one. Safe to call when nothing is prepared.
    func stop()
    /// Whether the engine is running now. False after it stopped itself (e.g. on a configuration change mid-start).
    var isRunning: Bool { get }
    /// The input format the hardware reports now (it may differ from the one `prepare` returned after a change).
    func currentFormat() -> InputFormat?
    /// Called from any thread when the hardware configuration changes under the prepared graph
    /// (`AVAudioEngineConfigurationChange`). Set before `prepare`; kept across `stop` and `prepare`.
    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?)
    /// Default input / output for diagnostics (transport, rate, channels, running). No names.
    func routeDescription() -> String
}

extension MicrophoneEngine {
    public func routeDescription() -> String { "unavailable" }
}

/// `AVAudioEngine` input node with a tap that copies each buffer into the ring.
/// One instance belongs to exactly one `MicrophoneSource`; do not share it between sources.
public final class AVMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {   // mutated only on the source's control queue
    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?
    private var observer: (any NSObjectProtocol)?
    /// Read from the notification's thread, so behind a lock (in a class so the observer block can hold it).
    private final class HandlerBox: Sendable {
        let value = Mutex<(@Sendable () -> Void)?>(nil)
    }
    private let handler = HandlerBox()

    public init() {}

    public var isRunning: Bool { engine?.isRunning ?? false }

    public func currentFormat() -> InputFormat? {
        guard let engine else { return nil }
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return nil }
        return InputFormat(sampleRate: fmt.sampleRate, channels: Int(fmt.channelCount))
    }

    public func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        self.handler.value.withLock { $0 = handler }
    }

    public func routeDescription() -> String { AudioRoute.describeDefaults() }

    /// AVAudioEngine → voice processing (before the device) → current device → input format.
    public func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) } catch {
                throw AudioSourceError.coreAudio(call: "setVoiceProcessingEnabled", status: OSStatus(truncatingIfNeeded: (error as NSError).code))
            }
        }
        if var id = deviceID {
            guard let unit = input.audioUnit else {
                throw AudioSourceError.coreAudio(call: "AudioUnitSetProperty", status: kAudioUnitErr_Uninitialized)
            }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioSourceError.coreAudio(call: "AudioUnitSetProperty", status: status) }
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.commonFormat == .pcmFormatFloat32, fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw AudioSourceError.unsupportedFormat
        }
        self.engine = engine
        self.format = fmt
        let handler = self.handler
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            handler.value.withLock { $0 }?()
        }
        return InputFormat(sampleRate: fmt.sampleRate, channels: Int(fmt.channelCount))
    }

    /// installTap → prepare → start.
    public func start(writingTo ring: AudioRingBuffer) throws {
        guard let engine, let format else { throw AudioSourceError.unsupportedFormat }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTapBlock(ring: ring))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioSourceError.coreAudio(call: "AVAudioEngine.start", status: OSStatus(truncatingIfNeeded: (error as NSError).code))
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.format = nil
    }

    /// The render-thread body: copy into the ring and nothing else (no locks, allocation, logging or I/O).
    nonisolated static func makeTapBlock(ring: AudioRingBuffer) -> AVAudioNodeTapBlock {
        { buffer, when in
            guard when.isHostTimeValid else { return }   // no timeline position; never stamp host time 0
            ring.write(buffer.audioBufferList, frameCount: Int(buffer.frameLength), hostTime: when.hostTime, sampleTime: Double(when.sampleTime))
        }
    }
}
