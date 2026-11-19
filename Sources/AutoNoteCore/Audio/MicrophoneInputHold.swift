import Foundation
import CoreAudio
import Synchronization
import os

/// Keeps a Bluetooth input device open for the whole recording, apart from the microphone engine.
///
/// Why: a Bluetooth headset only stays on HFP (the profile with a microphone) while someone uses its input. When
/// `MicrophoneSource` rebuilds the engine, the engine stop leaves the input unused, the headset falls back to A2DP
/// within about 0.4 s, and the next `start` asks for HFP again: the switch lands about 0.6 s later and stops the new
/// engine as well (`iounit configuration changed > stopping the engine`), over and over. Observed on the real headset
/// with a browser playing audio. Holding the input with a no-op IOProc keeps HFP up across rebuilds.
public protocol MicrophoneInputHolding: Sendable {
    /// Releases what it holds, then opens `deviceID` (nil = the default input now) when it is a Bluetooth input.
    /// Returns whether it holds one.
    func hold(deviceID: AudioDeviceID?) -> Bool
    /// Whether it holds the live device `deviceID` resolves to (nil = the default input now). False when the held
    /// device was replaced (a new default input, a device that disappeared and came back with a new ID) or holds none.
    func isHolding(deviceID: AudioDeviceID?) -> Bool
    /// Whether the held device has delivered input without a gap for at least `duration` (the profile has settled).
    /// True when nothing is held.
    func isSteady(for duration: Duration) -> Bool
    func release()
}

/// Holds nothing: tests and non-Bluetooth setups.
public struct NoMicrophoneInputHold: MicrophoneInputHolding {
    public init() {}
    public func hold(deviceID: AudioDeviceID?) -> Bool { false }
    public func isHolding(deviceID: AudioDeviceID?) -> Bool { false }
    public func isSteady(for duration: Duration) -> Bool { true }
    public func release() {}
}

/// When the held input last delivered, and since when without a gap. Written by the IOProc (one writer, lock-free),
/// read by `isSteady`; times are `DispatchTime` uptime nanoseconds. Subtractions saturate at 0: a reader's `now` may
/// be older than a callback stamped after it was read.
final class HeldInputTimes: Sendable {
    /// A gap longer than this between callbacks starts a new steady run (a profile switch stops the IO for longer).
    static let gapNanos: UInt64 = 150_000_000

    private let lastCallback = Atomic<UInt64>(0)
    private let runStart = Atomic<UInt64>(0)

    init() {}

    /// Real-time safe: two atomic loads and stores.
    func noteCallback(now: UInt64) {
        let last = lastCallback.load(ordering: .relaxed)
        if last == 0 || Self.elapsed(from: last, to: now) > Self.gapNanos { runStart.store(now, ordering: .relaxed) }
        lastCallback.store(now, ordering: .releasing)
    }

    func isSteady(now: UInt64, need: UInt64) -> Bool {
        let last = lastCallback.load(ordering: .acquiring)
        let start = runStart.load(ordering: .relaxed)
        return last != 0 && Self.elapsed(from: last, to: now) <= Self.gapNanos && Self.elapsed(from: start, to: now) >= need
    }

    func reset() {
        runStart.store(0, ordering: .relaxed)
        lastCallback.store(0, ordering: .releasing)
    }

    static func elapsed(from earlier: UInt64, to now: UInt64) -> UInt64 { now >= earlier ? now - earlier : 0 }
}

/// Core Audio: an IOProc on the device that only notes when input arrives. Bluetooth (classic and LE) only.
public final class CoreAudioBluetoothInputHold: MicrophoneInputHolding, Sendable {
    private struct Held: Sendable {
        var device: AudioObjectID
        var proc: AudioDeviceIOProcID
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "MicrophoneSource")

    private let held = Mutex<Held?>(nil)
    private let times = HeldInputTimes()
    private let queue = DispatchQueue(label: "com.yutaokoshi.autonote.mic.hold", qos: .userInitiated)

    public init() {}

    deinit { release() }

    /// Bluetooth (classic or LE) input device: what the hold and the HAL microphone engine apply to.
    static func isBluetoothInput(_ device: AudioObjectID) -> Bool {
        CoreAudioHardware.transport(coreAudio: CoreAudioHardware.uint32Prop(device, kAudioDevicePropertyTransportType)) == .bluetooth
            && CoreAudioHardware.channelCount(device, kAudioObjectPropertyScopeInput) > 0
    }

    public func hold(deviceID: AudioDeviceID?) -> Bool {
        release()
        guard let device = deviceID ?? AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
              Self.isBluetoothInput(device) else { return false }
        times.reset()
        let times = self.times
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, _, _, _, _ in
            times.noteCallback(now: DispatchTime.now().uptimeNanoseconds)
        }
        guard status == noErr, let proc else {
            Self.logger.error("mic input hold: IOProc not created (\(status, privacy: .public))")
            return false
        }
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            Self.logger.error("mic input hold: start failed (\(status, privacy: .public))")
            return false
        }
        held.withLock { $0 = Held(device: device, proc: proc) }
        Self.logger.notice("mic input hold started (bluetooth input kept open for the recording) \(AudioRoute.describeDefaults(), privacy: .public)")
        return true
    }

    public func isHolding(deviceID: AudioDeviceID?) -> Bool {
        guard let device = held.withLock({ $0?.device }),
              device == (deviceID ?? AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) else { return false }
        return CoreAudioHardware.uint32Prop(device, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? false
    }

    public func isSteady(for duration: Duration) -> Bool {
        guard held.withLock({ $0 != nil }) else { return true }
        let c = duration.components
        let need = UInt64(max(0, c.seconds)) * 1_000_000_000 + UInt64(max(0, c.attoseconds) / 1_000_000_000)
        return times.isSteady(now: DispatchTime.now().uptimeNanoseconds, need: need)
    }

    public func release() {
        guard let h = held.withLock({ h -> Held? in defer { h = nil }; return h }) else { return }
        AudioDeviceStop(h.device, h.proc)
        AudioDeviceDestroyIOProcID(h.device, h.proc)
        Self.logger.notice("mic input hold released")
    }
}
