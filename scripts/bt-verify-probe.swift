// scripts/bt-verify.sh の補助。既定の入力・出力デバイスの状態を JSON で 1 回だけ表示する（読むだけ。何も変えない）。
// 使い方: swiftc -O scripts/bt-verify-probe.swift -o <out>/probe && <out>/probe
// 出力: {"default_output": {...}, "default_input": {...}}。各要素は name・transport・sample_rate・in_channels・
//       out_channels・running_somewhere。name は bt-verify.sh が --bt-name の照合にだけ使い、表には出さない。
import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var a = address(selector)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
    return id
}

func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var a = address(selector)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func name(_ id: AudioObjectID) -> String {
    var a = address(kAudioObjectPropertyName)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let ref else { return "" }
    return ref.takeRetainedValue() as String
}

func rate(_ id: AudioObjectID) -> Double {
    var a = address(kAudioDevicePropertyNominalSampleRate)
    var v: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : 0
}

func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transport(_ id: AudioObjectID) -> String {
    switch uint32(id, kAudioDevicePropertyTransportType) {
    case kAudioDeviceTransportTypeBuiltIn: "builtin"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
    case kAudioDeviceTransportTypeUSB: "usb"
    case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: "aggregate"
    case kAudioDeviceTransportTypeVirtual: "virtual"
    default: "unknown"
    }
}

func describe(_ id: AudioObjectID?) -> Any {
    guard let id else { return NSNull() }
    return [
        "name": name(id), "transport": transport(id), "sample_rate": rate(id),
        "in_channels": channels(id, kAudioObjectPropertyScopeInput), "out_channels": channels(id, kAudioObjectPropertyScopeOutput),
        "running_somewhere": (uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0,
    ] as [String: Any]
}

let out: [String: Any] = [
    "default_output": describe(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
    "default_input": describe(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)),
]
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
