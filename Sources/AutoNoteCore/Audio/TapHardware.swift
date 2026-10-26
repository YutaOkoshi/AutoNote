import Foundation
import CoreAudio

public struct TapSpec: Sendable, Equatable {
    public var excludeBundleIDs: [String]
    public var isPrivate: Bool = true
    public var muted: Bool = false

    public init(excludeBundleIDs: [String], isPrivate: Bool = true, muted: Bool = false) {
        self.excludeBundleIDs = excludeBundleIDs; self.isPrivate = isPrivate; self.muted = muted
    }
}

/// `tapOnly`: the aggregate holds only the tap. `withOutputClock`: also the default output device as main sub-device.
public enum AggregateLayout: Sendable {
    case tapOnly, withOutputClock
}

/// The Core Audio calls `ProcessTapSource` needs, one method per call, so the source can be tested with a fake.
public protocol TapHardware: Sendable {
    func createTap(_ spec: TapSpec) throws -> (id: AudioObjectID, uuid: String)
    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription
    func defaultOutputDeviceUID() throws -> String
    func createAggregate(_ description: [String: any Sendable]) throws -> AudioObjectID
    func createIOProc(_ device: AudioObjectID, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID
    func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws
    func stop(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws
    func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws
    func destroyAggregate(_ device: AudioObjectID) throws
    func destroyTap(_ tap: AudioObjectID) throws
}

/// Production glue: each method maps 1:1 to a Core Audio call. Not unit-tested (needs a device).
public struct CoreAudioTapHardware: TapHardware {
    public init() {}

    private static func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw AudioSourceError.coreAudio(call: call, status: status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    public func createTap(_ spec: TapSpec) throws -> (id: AudioObjectID, uuid: String) {
        // Global stereo tap; `exclusive` is true for this initializer, so `bundleIDs` lists processes to leave out.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "AutoNote system audio"
        desc.bundleIDs = spec.excludeBundleIDs
        desc.isPrivate = spec.isPrivate
        desc.muteBehavior = spec.muted ? .muted : .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(desc, &tap), "AudioHardwareCreateProcessTap")
        return (tap, desc.uuid.uuidString)
    }

    public func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = Self.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd), "AudioObjectGetPropertyData(kAudioTapPropertyFormat)")
        return asbd
    }

    public func defaultOutputDeviceUID() throws -> String {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
                       "AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultOutputDevice)")
        var uidAddr = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try Self.check(AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &size, &uid),
                       "AudioObjectGetPropertyData(kAudioDevicePropertyDeviceUID)")
        guard let uid else { throw AudioSourceError.deviceNotFound(uid: "") }
        return uid.takeRetainedValue() as String
    }

    public func createAggregate(_ description: [String: any Sendable]) throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        let dict = description as [String: Any] as NSDictionary
        try Self.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &device), "AudioHardwareCreateAggregateDevice")
        return device
    }

    public func createIOProc(_ device: AudioObjectID, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID {
        var proc: AudioDeviceIOProcID?
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue, block), "AudioDeviceCreateIOProcIDWithBlock")
        guard let proc else { throw AudioSourceError.coreAudio(call: "AudioDeviceCreateIOProcIDWithBlock", status: kAudioHardwareUnspecifiedError) }
        return proc
    }

    public func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws {
        try Self.check(AudioDeviceStart(device, proc), "AudioDeviceStart")
    }

    public func stop(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws {
        try Self.check(AudioDeviceStop(device, proc), "AudioDeviceStop")
    }

    public func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws {
        try Self.check(AudioDeviceDestroyIOProcID(device, proc), "AudioDeviceDestroyIOProcID")
    }

    public func destroyAggregate(_ device: AudioObjectID) throws {
        try Self.check(AudioHardwareDestroyAggregateDevice(device), "AudioHardwareDestroyAggregateDevice")
    }

    public func destroyTap(_ tap: AudioObjectID) throws {
        try Self.check(AudioHardwareDestroyProcessTap(tap), "AudioHardwareDestroyProcessTap")
    }
}
