import Foundation
import CoreAudio

public protocol AudioDeviceLookup: Sendable {
    /// Core Audio device for `uid`, or nil when no such device is present.
    func deviceID(forUID uid: String) -> AudioDeviceID?
    /// Name, UID and transport of `uid` (nil = the system default input), or nil when it cannot be resolved.
    func deviceRef(forUID uid: String?) -> DeviceRef?
}

public struct CoreAudioDeviceLookup: AudioDeviceLookup {
    public init() {}

    public func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    public func deviceRef(forUID uid: String?) -> DeviceRef? {
        let id: AudioDeviceID
        if let uid {
            guard let found = deviceID(forUID: uid) else { return nil }
            id = found
        } else {
            guard let found = Self.defaultInputDevice() else { return nil }
            id = found
        }
        guard let name = Self.string(id, kAudioObjectPropertyName),
              let deviceUID = Self.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return DeviceRef(name: name, uid: deviceUID, transport: Self.transport(Self.uint32(id, kAudioDevicePropertyTransportType)))
    }

    static func transport(_ type: UInt32?) -> String {
        CoreAudioHardware.transport(coreAudio: type).rawValue
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
