// DeviceProbe — オーディオ機器の識別子と接続イベントを 1 行 1 JSON で出し続けるスパイク（計画 00 Task 4）。
//
// 使い方: .build/debug/DeviceProbe | tee /tmp/devices.jsonl   （Ctrl-C で終了）
//
// 出力:
//   起動時: 入力チャンネルを持つ機器ごとに {"event":"present", ...}、続けて既定の入力機器を {"event":"defaultInput", ...}
//   以後:   {"event":"added|removed|dataSourceChanged|defaultInputChanged", "at": ISO8601, ...}
//   各行の項目: name / deviceUID / modelUID / transportType / manufacturer / deviceID /
//              inputChannels / outputChannels / dataSource（内蔵のみ。{"id","name"}）/ outputDataSource（内蔵の出力側）
//
// 前提・判断:
//   - added / removed は出力専用の機器も出す（inputChannels で絞れる）。3.5mm のヘッドホン（マイクなし）や、
//     Bluetooth が出力だけ先に現れる場合を見落とさないため。起動時の present は要件どおり入力ありのみ。
//   - removed の行は、消えた機器にはもう問い合わせできないので、最後に読めた値（キャッシュ）を出す。
//   - 内蔵機器の DataSource は入力スコープと出力スコープの両方にリスナーを付ける（scope 項目で区別）。
//   - main.swift のトップレベルのクロージャは @MainActor に推論され、別スレッドから呼ばれると SIGILL になる
//     （Task 3 の実測）。リスナーのブロックはすべて Probe クラスのメソッド内で作る。

import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Core Audio の読み取りヘルパー

nonisolated func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

nonisolated func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
    return r.takeRetainedValue() as String
}

nonisolated func uint32Prop(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32?
{
    var a = addr(sel, scope)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

nonisolated func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

nonisolated func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

nonisolated func transportName(_ t: UInt32?) -> String {
    guard let t else { return "Unknown(nil)" }
    switch t {
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypePCI: return "PCI"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    default: return String(format: "Unknown(0x%08x)", t)
    }
}

/// DataSource の値と名前（kAudioDevicePropertyDataSourceNameForIDCFString）。持たない機器は nil。
nonisolated func dataSource(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [String: Any]? {
    guard var src = uint32Prop(id, kAudioDevicePropertyDataSource, scope) else { return nil }
    var a = addr(kAudioDevicePropertyDataSourceNameForIDCFString, scope)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
    let st = withUnsafeMutablePointer(to: &src) { srcP in
        withUnsafeMutablePointer(to: &name) { nameP in
            var t = AudioValueTranslation(
                mInputData: srcP, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                mOutputData: nameP, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        }
    }
    var d: [String: Any] = ["id": src, "fourCC": fourCC(src)]
    if st == noErr, let n = name { d["name"] = n.takeRetainedValue() as String }
    return d
}

nonisolated func fourCC(_ v: UInt32) -> String {
    let b = withUnsafeBytes(of: v.bigEndian) { Array($0) }
    return String(b.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "?" })
}

nonisolated func describe(_ id: AudioObjectID) -> [String: Any] {
    let transport = uint32Prop(id, kAudioDevicePropertyTransportType)
    var d: [String: Any] = [
        "deviceID": id,
        "name": stringProp(id, kAudioObjectPropertyName) ?? NSNull(),
        "deviceUID": stringProp(id, kAudioDevicePropertyDeviceUID) ?? NSNull(),
        "modelUID": stringProp(id, kAudioDevicePropertyModelUID) ?? NSNull(),
        "manufacturer": stringProp(id, kAudioObjectPropertyManufacturer) ?? NSNull(),
        "transportType": transportName(transport),
        "inputChannels": channelCount(id, kAudioObjectPropertyScopeInput),
        "outputChannels": channelCount(id, kAudioObjectPropertyScopeOutput),
    ]
    if transport == kAudioDeviceTransportTypeBuiltIn {
        if let s = dataSource(id, kAudioObjectPropertyScopeInput) { d["dataSource"] = s }
        if let s = dataSource(id, kAudioObjectPropertyScopeOutput) { d["outputDataSource"] = s }
    }
    return d
}

// MARK: - 監視

final class Probe: @unchecked Sendable {
    // すべて queue の上でだけ触る
    let queue = DispatchQueue(label: "DeviceProbe.listener")
    let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()
    var known: [AudioObjectID: [String: Any]] = [:]
    var dataSourceListened: Set<AudioObjectID> = []
    var defaultInput: AudioObjectID = 0

    func emit(_ event: String, _ fields: [String: Any], extra: [String: Any] = [:]) {
        var d = fields
        d["event"] = event
        d["at"] = iso.string(from: Date())
        for (k, v) in extra { d[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes]),
            let s = String(data: data, encoding: .utf8)
        else { print("{\"event\":\"error\",\"reason\":\"json\"}"); return }
        print(s)
    }

    func start() {
        queue.sync {
            for id in allDevices() {
                let d = describe(id)
                known[id] = d
                if (d["inputChannels"] as? Int ?? 0) > 0 { emit("present", d) }
                listenDataSourceIfBuiltIn(id, d)
            }
            defaultInput = uint32Prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) ?? 0
            emit("defaultInput", known[defaultInput] ?? ["deviceID": defaultInput])
        }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a1 = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(sys, &a1, queue) { [self] _, _ in devicesChanged() }
        var a2 = addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(sys, &a2, queue) { [self] _, _ in defaultInputChanged() }
    }

    func listenDataSourceIfBuiltIn(_ id: AudioObjectID, _ d: [String: Any]) {
        guard d["transportType"] as? String == "BuiltIn", !dataSourceListened.contains(id) else { return }
        dataSourceListened.insert(id)
        for (scope, label) in [(kAudioObjectPropertyScopeInput, "input"), (kAudioObjectPropertyScopeOutput, "output")] {
            var a = addr(kAudioDevicePropertyDataSource, scope)
            guard AudioObjectHasProperty(id, &a) else { continue }
            AudioObjectAddPropertyListenerBlock(id, &a, queue) { [self] _, _ in
                let nd = describe(id)
                known[id] = nd
                emit("dataSourceChanged", nd, extra: ["scope": label])
            }
        }
    }

    func devicesChanged() {
        let now = Set(allDevices())
        let before = Set(known.keys)
        for id in before.subtracting(now).sorted() {
            emit("removed", known[id] ?? ["deviceID": id])
            known[id] = nil
            dataSourceListened.remove(id)  // 消えた機器のリスナーは外さない（スパイク）
        }
        for id in now.subtracting(before).sorted() {
            let d = describe(id)
            known[id] = d
            emit("added", d)
            listenDataSourceIfBuiltIn(id, d)
        }
    }

    func defaultInputChanged() {
        let id = uint32Prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) ?? 0
        let d = describe(id)
        if known[id] != nil { known[id] = d }
        emit("defaultInputChanged", d, extra: ["previousDeviceID": defaultInput])
        defaultInput = id
    }

    // Ctrl-C で終了
    var sigSource: DispatchSourceSignal?
    func installSigint() {
        signal(SIGINT, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        s.setEventHandler { [self] in
            emit("stopped", [:])
            exit(0)
        }
        s.resume()
        sigSource = s
    }
}

let probe = Probe()
probe.installSigint()
probe.start()
dispatchMain()
