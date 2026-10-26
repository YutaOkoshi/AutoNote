import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test func bluetoothInputIsIndividualCandidate() {
    let id = DeviceIdentity(raw: .fixtureBluetoothInput)!
    #expect(id.transport == .bluetooth); #expect(id.uidKind == .individual); #expect(id.isAutoRecordCandidate)
    #expect(id.modelUID == "0 0")
    #expect(id.deviceRef == DeviceRef(name: "Fictional BT Headset", uid: "00-11-22-33-44-55:input", transport: "bluetooth"))
}

@Test func headphoneJackInputIsFixed() {
    let id = DeviceIdentity(raw: .fixtureHeadphoneInput)!
    #expect(id.deviceUID == "BuiltInHeadphoneInputDevice"); #expect(id.modelUID == "Codec Input")
    #expect(id.uidKind == .fixed); #expect(id.isAutoRecordCandidate)
    #expect(id.deviceRef.transport == "builtin")
}

@Test func builtInMicrophoneIsFixedCandidate() {
    let id = DeviceIdentity(raw: .fixtureBuiltInMicrophone)!
    #expect(id.uidKind == .fixed); #expect(id.isAutoRecordCandidate)
}

@Test func outputOnlyDeviceHasNoIdentity() {
    #expect(DeviceIdentity(raw: .fixtureBluetoothOutput) == nil)
}

@Test func missingDeviceUIDHasNoIdentity() {
    var raw = RawAudioDevice.fixtureBuiltInMicrophone; raw.deviceUID = nil
    #expect(DeviceIdentity(raw: raw) == nil)
}

@Test func missingNameFallsBackToDeviceUID() {
    var raw = RawAudioDevice.fixtureBluetoothInput; raw.name = nil
    let id = DeviceIdentity(raw: raw)!
    #expect(id.name == "00-11-22-33-44-55:input")
}

@Test func aggregateAndVirtualAreNotCandidates() {
    #expect(DeviceIdentity(raw: .fixtureAggregate)!.isAutoRecordCandidate == false)
    #expect(DeviceIdentity(raw: .fixtureVirtual)!.isAutoRecordCandidate == false)
    #expect(DeviceIdentity(raw: .fixtureProcessTapAggregate)!.isAutoRecordCandidate == false)
}

@Test(arguments: [
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset:ABC123XYZ:1", UIDKind.individual),
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset:14200000:1", .portBased),
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset::1", .portBased),
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset:14200001:1", .individual),
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset:ZZZZ0000:1", .individual),
    ("FictionalVendorDriver_0042", .unknown),
]) func usbUIDKindEstimate(uid: String, expected: UIDKind) {
    #expect(DeviceIdentity(raw: .fixtureUSBInput(uid: uid))!.uidKind == expected)
}

@Test func deviceRefUsesLowercaseTransport() {
    #expect(DeviceIdentity(raw: .fixtureUSBInput(uid: "x"))!.deviceRef.transport == "usb")
    var raw = RawAudioDevice.fixtureBuiltInMicrophone; raw.transport = .unknown
    let id = DeviceIdentity(raw: raw)!
    #expect(id.deviceRef.transport == "unknown"); #expect(id.uidKind == .unknown)
}

@Test func deviceIdentityRoundTripsWithSnakeCaseKeys() throws {
    let id = DeviceIdentity(raw: .fixtureBluetoothInput)!
    let s = String(decoding: try AutoNoteJSON.encoder().encode(id), as: UTF8.self)
    for key in ["device_uid", "model_uid", "input_channels", "uid_kind"] { #expect(s.contains("\"\(key)\"")) }
    #expect(try AutoNoteJSON.decoder().decode(DeviceIdentity.self, from: Data(s.utf8)) == id)
}

@Test func deviceIdentityWithNilModelUIDRoundTrips() throws {
    var raw = RawAudioDevice.fixtureBluetoothInput; raw.modelUID = nil
    let id = DeviceIdentity(raw: raw)!
    let s = String(decoding: try AutoNoteJSON.encoder().encode(id), as: UTF8.self)
    #expect(!s.contains("\"model_uid\" : \"")) // omitted or null, never a string
    let back = try AutoNoteJSON.decoder().decode(DeviceIdentity.self, from: Data(s.utf8))
    #expect(back == id); #expect(back.modelUID == nil)
}
