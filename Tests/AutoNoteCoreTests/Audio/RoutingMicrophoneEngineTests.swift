import Testing
import Foundation
import CoreAudio
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct RoutingMicrophoneEngineTests {
    private final class Flag: Sendable {
        let value = Mutex(false)
    }

    @Test func aBluetoothInputUsesTheHALEngineAndOthersAVAudioEngine() throws {
        let av = FakeMicrophoneEngine(), hal = FakeMicrophoneEngine()
        hal.format = InputFormat(sampleRate: 16_000, channels: 1)
        let engine = RoutingMicrophoneEngine(av: av, hal: hal, usesHAL: { id, vp in id == 7 && !vp })
        #expect(try engine.prepare(deviceID: 7, voiceProcessing: false) == InputFormat(sampleRate: 16_000, channels: 1))
        #expect(hal.prepareCount == 1 && av.prepareCount == 0)
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 16_000, recordCapacity: 16)
        try engine.start(writingTo: ring)
        #expect(engine.isRunning && hal.isRunning)
        engine.stop()
        #expect(hal.isStopped && !engine.isRunning)

        _ = try engine.prepare(deviceID: 7, voiceProcessing: true)
        #expect(av.prepareCount == 1)
        _ = try engine.prepare(deviceID: 3, voiceProcessing: false)
        #expect(av.prepareCount == 2 && hal.prepareCount == 1)
    }

    @Test func switchingEnginesStopsThePreviousOne() throws {
        let av = FakeMicrophoneEngine(), hal = FakeMicrophoneEngine()
        let engine = RoutingMicrophoneEngine(av: av, hal: hal, usesHAL: { id, _ in id == 7 })
        _ = try engine.prepare(deviceID: 7, voiceProcessing: false)
        try engine.start(writingTo: AudioRingBuffer(channels: 1, capacityFrames: 4800, recordCapacity: 16))
        _ = try engine.prepare(deviceID: 3, voiceProcessing: false)
        #expect(!hal.isRunning && hal.isStopped)
    }

    @Test func theConfigurationChangeHandlerReachesBothEngines() throws {
        let av = FakeMicrophoneEngine(), hal = FakeMicrophoneEngine()
        let engine = RoutingMicrophoneEngine(av: av, hal: hal, usesHAL: { _, _ in true })
        let called = Flag()
        engine.setConfigurationChangeHandler { called.value.withLock { $0 = true } }
        hal.simulateConfigurationChange(stopEngine: false)
        #expect(called.value.withLock { $0 })
        called.value.withLock { $0 = false }
        av.simulateConfigurationChange(stopEngine: false)
        #expect(called.value.withLock { $0 })
    }
}

/// REVIEW.md M2 on the routing level: recording from the default input, a new default input means a rebuild whichever
/// engine runs (AVAudioEngine would otherwise follow a new Bluetooth default itself and wait seconds in its own
/// Bluetooth format setup, as seen on the real headset).
@Suite struct RoutingMicrophoneEngineDefaultInputTests {
    private final class DefaultInput: Sendable {
        let id = Mutex<AudioObjectID?>(5)
    }

    @Test func aNewDefaultInputNeedsARebuildWhenThePreparedGraphFollowedTheDefault() throws {
        let av = FakeMicrophoneEngine(), hal = FakeMicrophoneEngine()
        let current = DefaultInput()
        let engine = RoutingMicrophoneEngine(av: av, hal: hal, usesHAL: { _, _ in false }, defaultInput: { current.id.withLock { $0 } })
        _ = try engine.prepare(deviceID: nil, voiceProcessing: false)
        #expect(!engine.needsRebuild)
        current.id.withLock { $0 = 9 }
        #expect(engine.needsRebuild)
        _ = try engine.prepare(deviceID: nil, voiceProcessing: false)
        #expect(!engine.needsRebuild)
    }

    @Test func aFixedDeviceIgnoresTheDefaultInput() throws {
        let av = FakeMicrophoneEngine(), hal = FakeMicrophoneEngine()
        let current = DefaultInput()
        let engine = RoutingMicrophoneEngine(av: av, hal: hal, usesHAL: { _, _ in false }, defaultInput: { current.id.withLock { $0 } })
        _ = try engine.prepare(deviceID: 3, voiceProcessing: false)
        current.id.withLock { $0 = 9 }
        #expect(!engine.needsRebuild)
        av.needsRebuild = true
        #expect(engine.needsRebuild)   // the active engine's own staleness still counts
    }
}
