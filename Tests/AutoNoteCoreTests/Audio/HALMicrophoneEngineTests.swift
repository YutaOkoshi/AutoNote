import Testing
import Foundation
import CoreAudio
@testable import AutoNoteCore

/// The device-free parts of the HAL path: the IOProc body, the format check, the routing and staleness rules, and the
/// hold's steady-run arithmetic (REVIEW.md M1, M2, L5 and the test gaps it listed).
@Suite struct HALMicrophoneEngineTests {
    private static func floatPCM(rate: Double = 16_000, channels: UInt32 = 1, bits: UInt32 = 32,
                                 flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                    mBytesPerPacket: channels * bits / 8, mFramesPerPacket: 1, mBytesPerFrame: channels * bits / 8,
                                    mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
    }

    @Test func acceptsOneInterleavedFloat32Stream() {
        #expect(HALMicrophoneEngine.inputFormat(streamCount: 1, asbd: Self.floatPCM()) == InputFormat(sampleRate: 16_000, channels: 1))
        #expect(HALMicrophoneEngine.inputFormat(streamCount: 1, asbd: Self.floatPCM(rate: 48_000, channels: 2)) == InputFormat(sampleRate: 48_000, channels: 2))
    }

    @Test func refusesWhatTheRingCannotTakeAsOneBuffer() {
        #expect(HALMicrophoneEngine.inputFormat(streamCount: 2, asbd: Self.floatPCM()) == nil)
        #expect(HALMicrophoneEngine.inputFormat(streamCount: 0, asbd: Self.floatPCM()) == nil)
        #expect(HALMicrophoneEngine.inputFormat(streamCount: 1, asbd: Self.floatPCM(channels: 2, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved)) == nil)
        #expect(HALMicrophoneEngine.inputFormat(streamCount: 1, asbd: Self.floatPCM(bits: 16, flags: kAudioFormatFlagIsSignedInteger)) == nil)
        #expect(HALMicrophoneEngine.inputFormat(streamCount: 1, asbd: Self.floatPCM(rate: 0)) == nil)
    }

    /// L5: Bluetooth LE counts as Bluetooth.
    @Test func choosesHALForClassicAndLEBluetoothWithoutVoiceProcessing() {
        #expect(RoutingMicrophoneEngine.choosesHAL(transportType: kAudioDeviceTransportTypeBluetooth, voiceProcessing: false, singleFloat32Stream: true))
        #expect(RoutingMicrophoneEngine.choosesHAL(transportType: kAudioDeviceTransportTypeBluetoothLE, voiceProcessing: false, singleFloat32Stream: true))
        #expect(!RoutingMicrophoneEngine.choosesHAL(transportType: kAudioDeviceTransportTypeBluetooth, voiceProcessing: true, singleFloat32Stream: true))
        #expect(!RoutingMicrophoneEngine.choosesHAL(transportType: kAudioDeviceTransportTypeBluetooth, voiceProcessing: false, singleFloat32Stream: false))
        #expect(!RoutingMicrophoneEngine.choosesHAL(transportType: kAudioDeviceTransportTypeBuiltIn, voiceProcessing: false, singleFloat32Stream: true))
        #expect(!RoutingMicrophoneEngine.choosesHAL(transportType: kAudioDeviceTransportTypeUSB, voiceProcessing: false, singleFloat32Stream: true))
        #expect(!RoutingMicrophoneEngine.choosesHAL(transportType: nil, voiceProcessing: false, singleFloat32Stream: true))
    }

    /// M2: a graph that followed the default input is stale once the default moves; a fixed device only when it died.
    @Test func staleWhenTheFollowedDefaultMovesOrTheDeviceDies() {
        #expect(HALMicrophoneEngine.isStale(followsDefault: true, device: 7, defaultInput: 9, alive: true))
        #expect(!HALMicrophoneEngine.isStale(followsDefault: true, device: 7, defaultInput: 7, alive: true))
        #expect(!HALMicrophoneEngine.isStale(followsDefault: true, device: 7, defaultInput: nil, alive: true))
        #expect(!HALMicrophoneEngine.isStale(followsDefault: false, device: 7, defaultInput: 9, alive: true))
        #expect(HALMicrophoneEngine.isStale(followsDefault: false, device: 7, defaultInput: 7, alive: false))
    }

    private func callIOBlock(_ block: AudioDeviceIOBlock, frames: Int, channels: UInt32, hostTime: UInt64, flags: AudioTimeStampFlags) {
        var samples = [Float](repeating: 0.5, count: frames * Int(channels))
        samples.withUnsafeMutableBytes { raw in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
            var now = AudioTimeStamp(), outTime = AudioTimeStamp()
            var inTime = AudioTimeStamp(); inTime.mHostTime = hostTime; inTime.mSampleTime = 0; inTime.mFlags = flags
            block(&now, &input, &inTime, &output, &outTime)
        }
    }

    @Test func theIOBlockWritesFramesWithTheirHostTime() {
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 16_000, recordCapacity: 16)
        callIOBlock(HALMicrophoneEngine.makeIOBlock(ring: ring), frames: 160, channels: 1, hostTime: 1_000, flags: [.hostTimeValid, .sampleTimeValid])
        #expect(ring.recordsWritten == 1)
    }

    @Test func theIOBlockSkipsInputWithoutAHostTimeOrOfTheWrongWidth() {
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 16_000, recordCapacity: 16)
        let block = HALMicrophoneEngine.makeIOBlock(ring: ring)
        callIOBlock(block, frames: 160, channels: 1, hostTime: 1_000, flags: [.sampleTimeValid])
        callIOBlock(block, frames: 160, channels: 1, hostTime: 0, flags: [.hostTimeValid])
        #expect(ring.recordsWritten == 0)
        let stereo = AudioRingBuffer(channels: 2, capacityFrames: 16_000, recordCapacity: 16)
        callIOBlock(HALMicrophoneEngine.makeIOBlock(ring: stereo), frames: 160, channels: 1, hostTime: 1_000, flags: [.hostTimeValid])
        #expect(stereo.recordsWritten == 0)   // dropped by the ring's layout check, not mis-read
    }

    /// M1: a callback stamped after the reader took `now` must not trap (UInt64 underflow) and counts as recent.
    @Test func aCallbackNewerThanTheReadersNowDoesNotTrap() {
        let t = HeldInputTimes()
        for ms in stride(from: 1_000, through: 1_500, by: 100) { t.noteCallback(now: UInt64(ms) * 1_000_000) }
        #expect(t.isSteady(now: 1_450_000_000, need: 300_000_000))   // reader's now is older than the last callback
        #expect(!t.isSteady(now: 1_450_000_000, need: 600_000_000))
        #expect(HeldInputTimes.elapsed(from: 5, to: 3) == 0)
    }

    @Test func aGapStartsANewSteadyRun() {
        let t = HeldInputTimes()
        #expect(!t.isSteady(now: 1, need: 0))   // no callback yet
        t.noteCallback(now: 1_000_000_000)
        t.noteCallback(now: 1_100_000_000)
        t.noteCallback(now: 1_500_000_000)      // 400 ms gap: a new run starts here
        #expect(!t.isSteady(now: 1_550_000_000, need: 300_000_000))
        t.noteCallback(now: 1_600_000_000); t.noteCallback(now: 1_700_000_000); t.noteCallback(now: 1_800_000_000)
        #expect(t.isSteady(now: 1_850_000_000, need: 300_000_000))
        #expect(!t.isSteady(now: 2_100_000_000, need: 300_000_000))   // nothing for 300 ms: not steady any more
        t.reset()
        #expect(!t.isSteady(now: 2_100_000_000, need: 0))
    }
}
