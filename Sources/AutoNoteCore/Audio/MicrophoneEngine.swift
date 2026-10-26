import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

public protocol MicrophonePermissionChecking: Sendable {
    func status() -> MicrophonePermissionStatus
}

/// Reads the current microphone authorization. Never requests it (plan 06's screen does that).
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
    func stop()
}

/// `AVAudioEngine` input node with a tap that copies each buffer into the ring.
public final class AVMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {   // mutated only on the source's control queue
    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?

    public init() {}

    /// AVAudioEngine → voice processing (before the device) → current device → input format.
    public func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat {
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
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.format = nil
    }

    /// The render-thread body: copy into the ring and nothing else (no locks, allocation, logging or I/O).
    nonisolated static func makeTapBlock(ring: AudioRingBuffer) -> AVAudioNodeTapBlock {
        { buffer, when in
            ring.write(buffer.audioBufferList, frameCount: Int(buffer.frameLength), hostTime: when.hostTime, sampleTime: Double(when.sampleTime))
        }
    }
}
