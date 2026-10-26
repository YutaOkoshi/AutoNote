import Testing
import CoreAudio
import Foundation
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct DeviceListDiffTests {
    @Test func outputAppearingFirstIsNotAnEvent() {
        var diff = DeviceListDiff()
        let first = diff.update(with: [.fixtureBluetoothOutput])
        #expect(first.added.isEmpty && first.removed.isEmpty)
        // 0.78 s later the input appears (appendix A order).
        let second = diff.update(with: [.fixtureBluetoothOutput, .fixtureBluetoothInput])
        #expect(second.added.map(\.deviceUID) == [RawAudioDevice.fixtureBluetoothInput.deviceUID])
        #expect(second.removed.isEmpty)
    }

    @Test func inputRemovalCarriesCachedIdentity() {
        var diff = DeviceListDiff()
        _ = diff.update(with: [.fixtureBluetoothOutput, .fixtureBluetoothInput])
        let result = diff.update(with: [])
        #expect(result.removed.count == 1)
        #expect(result.removed[0].name == "Fictional BT Headset")
        #expect(result.added.isEmpty)
        #expect(diff.known.isEmpty)
    }

    @Test func newAudioObjectIDWithSameUIDIsNoEvent() {
        var diff = DeviceListDiff()
        var device = RawAudioDevice.fixtureBluetoothInput
        device.audioObjectID = 149
        _ = diff.update(with: [device])
        device.audioObjectID = 161
        let result = diff.update(with: [device])
        #expect(result.added.isEmpty && result.removed.isEmpty)
    }

    @Test func aggregateAddedIsIgnored() {
        var diff = DeviceListDiff()
        _ = diff.update(with: [.fixtureBuiltInMicrophone])
        let result = diff.update(with: [.fixtureBuiltInMicrophone, .fixtureAggregate, .fixtureVirtual, .fixtureProcessTapAggregate])
        #expect(result.added.isEmpty && result.removed.isEmpty)
    }

    @Test func removedComesBeforeAdded() {
        var diff = DeviceListDiff()
        _ = diff.update(with: [.fixtureHeadphoneInput])
        let result = diff.update(with: [.fixtureBluetoothInput])
        #expect(result.removed.map(\.deviceUID) == [RawAudioDevice.fixtureHeadphoneInput.deviceUID])
        #expect(result.added.map(\.deviceUID) == [RawAudioDevice.fixtureBluetoothInput.deviceUID])
    }

    @Test func removedKeepsPreviousListOrder() {
        var diff = DeviceListDiff()
        _ = diff.update(with: [.fixtureBuiltInMicrophone, .fixtureHeadphoneInput, .fixtureBluetoothInput])
        let result = diff.update(with: [])
        #expect(result.removed.map(\.deviceUID) == [
            RawAudioDevice.fixtureBuiltInMicrophone.deviceUID!, RawAudioDevice.fixtureHeadphoneInput.deviceUID!,
            RawAudioDevice.fixtureBluetoothInput.deviceUID!])
    }

    @Test func sameUIDRefreshesStoredIdentity() {
        var diff = DeviceListDiff()
        _ = diff.update(with: [.fixtureBluetoothInput])
        var renamed = RawAudioDevice.fixtureBluetoothInput
        renamed.name = "Renamed Headset"
        let result = diff.update(with: [renamed])
        #expect(result.added.isEmpty && result.removed.isEmpty)
        #expect(diff.known[renamed.deviceUID!]?.name == "Renamed Headset")
    }

    @Test(arguments: [
        (kAudioDeviceTransportTypeBuiltIn, DeviceTransport.builtin),
        (kAudioDeviceTransportTypeBluetooth, .bluetooth),
        (kAudioDeviceTransportTypeBluetoothLE, .bluetooth),
        (kAudioDeviceTransportTypeUSB, .usb),
        (kAudioDeviceTransportTypeAggregate, .aggregate),
        (kAudioDeviceTransportTypeAutoAggregate, .aggregate),
        (kAudioDeviceTransportTypeVirtual, .virtual),
        (kAudioDeviceTransportTypeHDMI, .unknown),
        (0x12345678, .unknown),
    ] as [(UInt32, DeviceTransport)])
    func transportTable(code: UInt32, expected: DeviceTransport) {
        #expect(CoreAudioHardware.transport(coreAudio: code) == expected)
    }

    @Test func nilTransportIsUnknown() {
        #expect(CoreAudioHardware.transport(coreAudio: nil) == .unknown)
    }

    @Test func fakeHardwareDeliversChangesUntilCancelled() throws {
        let fake = FakeAudioHardware()
        fake.setDevices([.fixtureBuiltInMicrophone])
        #expect(fake.snapshot().count == 1)
        let counter = Counter()
        let observation = try fake.observeDeviceList { counter.bump() }
        fake.fireChange()
        observation.cancel(); observation.cancel()
        fake.fireChange()
        #expect(counter.value == 1)
        #expect(fake.observationCancelled)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
