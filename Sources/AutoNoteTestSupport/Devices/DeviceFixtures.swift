import Foundation
import AutoNoteCore

/// Fictional devices modelled on spec appendix A. No real identifiers.
extension RawAudioDevice {
    public static let fixtureBuiltInMicrophone = RawAudioDevice(
        audioObjectID: 41, name: "Fictional Built-in Microphone", deviceUID: "BuiltInMicrophoneDevice",
        modelUID: "Apple Inc.:Fictional Mac", transport: .builtin, inputChannels: 1, outputChannels: 0)

    public static let fixtureHeadphoneInput = RawAudioDevice(
        audioObjectID: 52, name: "Fictional Headphone Jack", deviceUID: "BuiltInHeadphoneInputDevice",
        modelUID: "Codec Input", transport: .builtin, inputChannels: 1, outputChannels: 0)

    public static let fixtureBluetoothInput = RawAudioDevice(
        audioObjectID: 63, name: "Fictional BT Headset", deviceUID: "00-11-22-33-44-55:input",
        modelUID: "0 0", transport: .bluetooth, inputChannels: 1, outputChannels: 0)

    public static let fixtureBluetoothOutput = RawAudioDevice(
        audioObjectID: 64, name: "Fictional BT Headset", deviceUID: "00-11-22-33-44-55:output",
        modelUID: "0 0", transport: .bluetooth, inputChannels: 0, outputChannels: 2)

    public static let fixtureAggregate = RawAudioDevice(
        audioObjectID: 75, name: "Fictional Aggregate", deviceUID: "FictionalAggregateUID",
        modelUID: nil, transport: .aggregate, inputChannels: 2, outputChannels: 2)

    public static let fixtureVirtual = RawAudioDevice(
        audioObjectID: 86, name: "Fictional Virtual Device", deviceUID: "FictionalVirtualDeviceUID",
        modelUID: nil, transport: .virtual, inputChannels: 2, outputChannels: 2)

    /// AutoNote's own process-tap aggregate: reports `.builtin` but must never count as hardware.
    public static let fixtureProcessTapAggregate = RawAudioDevice(
        audioObjectID: 97, name: "AutoNote Tap", deviceUID: "com.yutaokoshi.autonote.tap.0D3A0000-0000-0000-0000-000000000000",
        modelUID: nil, transport: .builtin, inputChannels: 2, outputChannels: 0)

    public static func fixtureUSBInput(uid: String) -> RawAudioDevice {
        RawAudioDevice(audioObjectID: 108, name: "Fictional USB Headset", deviceUID: uid,
                       modelUID: "Fictional Audio", transport: .usb, inputChannels: 1, outputChannels: 0)
    }
}
