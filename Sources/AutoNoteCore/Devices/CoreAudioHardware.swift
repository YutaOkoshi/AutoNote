import Foundation
import CoreAudio
import os

public protocol HardwareObservation: Sendable {
    /// Idempotent: a second call is a no-op.
    func cancel()
}

public protocol AudioHardwareQuerying: Sendable {
    func snapshot() -> [RawAudioDevice]
    func observeDeviceList(_ onChange: @Sendable @escaping () -> Void) throws -> any HardwareObservation
}

public struct CoreAudioHardwareError: Error, Equatable {
    public let status: Int32
}

/// Reads the device list from Core Audio. Stateless; listener state lives in `Observation`, guarded by its own queue.
public final class CoreAudioHardware: AudioHardwareQuerying {
    public init() {}

    public func snapshot() -> [RawAudioDevice] {
        Self.allDevices().map { id in
            RawAudioDevice(
                audioObjectID: id,
                name: Self.stringProp(id, kAudioObjectPropertyName),
                deviceUID: Self.stringProp(id, kAudioDevicePropertyDeviceUID),
                modelUID: Self.stringProp(id, kAudioDevicePropertyModelUID),
                transport: Self.transport(coreAudio: Self.uint32Prop(id, kAudioDevicePropertyTransportType)),
                inputChannels: Self.channelCount(id, kAudioObjectPropertyScopeInput),
                outputChannels: Self.channelCount(id, kAudioObjectPropertyScopeOutput))
        }
    }

    public func observeDeviceList(_ onChange: @Sendable @escaping () -> Void) throws -> any HardwareObservation {
        // The block is created inside this nonisolated method, never at top level (plan 00 Task 3: @MainActor inference -> SIGILL).
        let queue = DispatchQueue(label: "autonote.coreaudio.devicelist")
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var address = Self.address(kAudioHardwarePropertyDevices)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        guard status == noErr else { throw CoreAudioHardwareError(status: status) }
        return Observation(queue: queue, block: block)
    }

    public static func transport(coreAudio type: UInt32?) -> DeviceTransport {
        guard let type else { return .unknown }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtin
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .unknown
        }
    }

    /// `cancelled` is guarded by a lock (not the listener queue), so `cancel()` is safe to call from inside `onChange`,
    /// which runs on that queue. Only the first caller removes the listener.
    private final class Observation: HardwareObservation, @unchecked Sendable {
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
            self.queue = queue; self.block = block
        }

        func cancel() {
            let isFirst = cancelled.withLock { state -> Bool in
                if state { return false }
                state = true
                return true
            }
            guard isFirst else { return }
            var address = CoreAudioHardware.address(kAudioHardwarePropertyDevices)
            // The status is ignored on purpose: there is no recovery, and a failure only means the listener was already gone.
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }

        deinit { cancel() }
    }

    // MARK: - Core Audio reads (ported from the plan 00 DeviceProbe spike; see docs/superpowers/research/2026-10-24-spike-results.md)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProp(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    private static func uint32Prop(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func allDevices() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
