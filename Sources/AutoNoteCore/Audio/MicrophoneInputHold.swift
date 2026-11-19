import Foundation
import CoreAudio
import Synchronization
import os

/// Keeps a Bluetooth input device open for the whole recording, apart from `AVAudioEngine`.
///
/// Why: a Bluetooth headset only stays on HFP (the profile with a microphone) while someone uses its input. When
/// `MicrophoneSource` rebuilds the engine, the engine stop leaves the input unused, the headset falls back to A2DP
/// within about 0.4 s, and the next `start` asks for HFP again: the switch lands about 0.6 s later and stops the new
/// engine as well (`iounit configuration changed > stopping the engine`), over and over. Observed on the real headset
/// with a browser playing audio. Holding the input with a no-op IOProc keeps HFP up across rebuilds.
public protocol MicrophoneInputHolding: Sendable {
    /// Opens `deviceID` (nil = the default input) when it is a Bluetooth input. Returns whether it holds one.
    func hold(deviceID: AudioDeviceID?) -> Bool
    /// Whether the held device has delivered input without a gap for at least `duration` (the profile has settled).
    /// True when nothing is held.
    func isSteady(for duration: Duration) -> Bool
    func release()
}

/// Holds nothing: tests and non-Bluetooth setups.
public struct NoMicrophoneInputHold: MicrophoneInputHolding {
    public init() {}
    public func hold(deviceID: AudioDeviceID?) -> Bool { false }
    public func isSteady(for duration: Duration) -> Bool { true }
    public func release() {}
}

/// Core Audio: an IOProc on the device that only notes when input arrives. Bluetooth transport only.
public final class CoreAudioBluetoothInputHold: MicrophoneInputHolding, Sendable {
    private struct Held: Sendable {
        var device: AudioObjectID
        var proc: AudioDeviceIOProcID
    }

    private struct Times {
        var lastCallbackNanos: UInt64 = 0
        var runStartNanos: UInt64 = 0
    }

    /// A class so the IOProc block can capture it (a `Mutex` cannot be captured).
    private final class TimesBox: Sendable {
        let value = Mutex(Times())
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "MicrophoneSource")
    /// A gap longer than this between callbacks starts a new steady run (a profile switch stops the IO for longer).
    private static let gapNanos: UInt64 = 150_000_000

    private let held = Mutex<Held?>(nil)
    private let times = TimesBox()
    private let queue = DispatchQueue(label: "com.yutaokoshi.autonote.mic.hold", qos: .userInitiated)

    public init() {}

    deinit { release() }

    public func hold(deviceID: AudioDeviceID?) -> Bool {
        release()
        guard let device = deviceID ?? AudioRoute.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
              CoreAudioHardware.uint32Prop(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth,
              CoreAudioHardware.channelCount(device, kAudioObjectPropertyScopeInput) > 0 else { return false }
        times.value.withLock { $0 = Times() }
        let times = self.times
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, _, _, _, _ in
            let now = DispatchTime.now().uptimeNanoseconds
            times.value.withLock { t in
                if t.lastCallbackNanos == 0 || now - t.lastCallbackNanos > Self.gapNanos { t.runStartNanos = now }
                t.lastCallbackNanos = now
            }
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

    public func isSteady(for duration: Duration) -> Bool {
        guard held.withLock({ $0 != nil }) else { return true }
        let c = duration.components
        let need = UInt64(c.seconds) * 1_000_000_000 + UInt64(c.attoseconds / 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        return times.value.withLock { t in
            t.lastCallbackNanos != 0 && now - t.lastCallbackNanos <= Self.gapNanos && now - t.runStartNanos >= need
        }
    }

    public func release() {
        guard let h = held.withLock({ h -> Held? in defer { h = nil }; return h }) else { return }
        AudioDeviceStop(h.device, h.proc)
        AudioDeviceDestroyIOProcID(h.device, h.proc)
        Self.logger.notice("mic input hold released")
    }
}
