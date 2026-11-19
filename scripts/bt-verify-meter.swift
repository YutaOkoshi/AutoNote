// scripts/bt-verify.py の計測プロセス（AutoNote とは別のプロセス）。何も変えない（読む・聞くだけ）。
//   devices                      既定の入出力と全デバイスの状態を JSON で 1 回表示する
//   meter --seconds N --out F [--freqs 440,660] [--mic-uid UID] [--mic-after S] [--mic-if-hfp]
//       全プロセスのタップ（非公開の集約デバイス、ミュートしない）で出力に乗った音を聞き、0.5 秒ごとに 1 行の JSON を F に書く:
//       t（epoch 秒）、tap の rms・各周波数の振幅（dBFS、Goertzel）・コールバック数、既定の出力の transport・レート・動作中か。
//       --mic-uid を付けると、その入力デバイスにも IOProc を張り（--mic-after 秒後から。--mic-if-hfp ならその時点で
//       既定の出力が 24 kHz 以下 = HFP のときだけ）、同じ値を mic_* に書く。名前・UID はファイルに書かない。
import CoreAudio
import Foundation

// MARK: - Core Audio reads

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(s); var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func str(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var ref: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let ref else { return "" }
    return ref.takeRetainedValue() as String
}
func rate(_ id: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var v: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : 0
}
func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func transport(_ id: AudioObjectID) -> String {
    switch u32(id, kAudioDevicePropertyTransportType) {
    case kAudioDeviceTransportTypeBuiltIn: "builtin"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
    case kAudioDeviceTransportTypeUSB: "usb"
    case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: "aggregate"
    case kAudioDeviceTransportTypeVirtual: "virtual"
    default: "unknown"
    }
}
func defaultDevice(_ s: AudioObjectPropertySelector) -> AudioObjectID? {
    var a = addr(s); var id = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
    return id
}
func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0; let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func running(_ id: AudioObjectID) -> Bool { (u32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0 }
func deviceInfo(_ id: AudioObjectID?, names: Bool) -> Any {
    guard let id else { return NSNull() }
    var d: [String: Any] = ["transport": transport(id), "sample_rate": rate(id), "in_channels": channels(id, kAudioObjectPropertyScopeInput),
                            "out_channels": channels(id, kAudioObjectPropertyScopeOutput), "running_somewhere": running(id)]
    if names { d["name"] = str(id, kAudioObjectPropertyName); d["uid"] = str(id, kAudioDevicePropertyDeviceUID) }
    return d
}
func emit(_ obj: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
}

// MARK: - Analysis (on a serial queue, not the real-time thread)

final class Window: @unchecked Sendable {
    private var samples: [Float] = []
    private var callbacks = 0
    private let lock = NSLock()
    func add(_ p: UnsafePointer<Float>, frames: Int, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        for f in 0..<frames {
            var s: Float = 0
            for c in 0..<channels { s += p[f * channels + c] }
            samples.append(s / Float(channels))
        }
    }
    func take() -> ([Float], Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (samples, callbacks); samples = []; callbacks = 0; return r
    }
}

func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -200 }
func goertzel(_ x: [Float], _ f: Double, _ sr: Double) -> Double {   // amplitude estimate (peak, linear)
    guard !x.isEmpty, sr > 0 else { return 0 }
    let k = 2 * cos(2 * Double.pi * f / sr); var s1 = 0.0, s2 = 0.0
    for v in x { let s0 = Double(v) + k * s1 - s2; s2 = s1; s1 = s0 }
    let power = s1 * s1 + s2 * s2 - k * s1 * s2
    return 2 * sqrt(max(power, 0)) / Double(x.count)
}
func summarize(_ x: [Float], _ cb: Int, sr: Double, freqs: [Double], prefix: String) -> [String: Any] {
    var d: [String: Any] = ["\(prefix)callbacks": cb, "\(prefix)frames": x.count]
    let rms = x.isEmpty ? 0 : sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    d["\(prefix)rms_db"] = (db(rms) * 10).rounded() / 10
    d["\(prefix)all_zero"] = !x.isEmpty && !x.contains { $0 != 0 }
    for f in freqs { d["\(prefix)tone_\(Int(f))_db"] = (db(goertzel(x, f, sr)) * 10).rounded() / 10 }
    return d
}

struct IOFormat { var rate: Double; var channels: Int }
func streamFormat(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> IOFormat {
    IOFormat(rate: rate(id), channels: max(1, channels(id, scope)))
}

// MARK: - Commands

let args = CommandLine.arguments
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

if args.count >= 2, args[1] == "devices" {
    let names = args.contains("--names")
    print(emit(["default_output": deviceInfo(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice), names: names),
                "default_input": deviceInfo(defaultDevice(kAudioHardwarePropertyDefaultInputDevice), names: names),
                "devices": allDevices().map { deviceInfo($0, names: names) }]))
    exit(0)
}

guard args.count >= 2, args[1] == "meter", let secsS = opt("--seconds"), let secs = Double(secsS), let outPath = opt("--out") else {
    FileHandle.standardError.write("usage: bt-verify-meter devices [--names] | meter --seconds N --out FILE [--freqs 440,660] [--mic-uid UID] [--mic-after S] [--mic-if-hfp]\n".data(using: .utf8)!)
    exit(64)
}
let freqs = (opt("--freqs") ?? "440,660").split(separator: ",").compactMap { Double($0) }
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)!
let queue = DispatchQueue(label: "meter.io")

// Tap: all processes, unmuted, private.
let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.isPrivate = true; desc.muteBehavior = .unmuted; desc.name = "bt-verify meter"
var tap = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { print(emit(["error": "AudioHardwareCreateProcessTap"])); exit(3) }
var fa = addr(kAudioTapPropertyFormat); var asbd = AudioStreamBasicDescription(); var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
_ = AudioObjectGetPropertyData(tap, &fa, 0, nil, &fsize, &asbd)
let tapRate = asbd.mSampleRate, tapChannels = Int(max(1, asbd.mChannelsPerFrame))
let aggDesc: [String: Any] = [kAudioAggregateDeviceNameKey: "bt-verify meter", kAudioAggregateDeviceUIDKey: "bt-verify.meter." + UUID().uuidString,
                              kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
                              kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
var agg = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else { AudioHardwareDestroyProcessTap(tap); print(emit(["error": "AudioHardwareCreateAggregateDevice"])); exit(3) }
let tapWindow = Window()
var tapProc: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&tapProc, agg, queue) { _, input, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let b = abl.first, let data = b.mData else { return }
    let ch = Int(b.mNumberChannels); guard ch > 0 else { return }
    tapWindow.add(data.assumingMemoryBound(to: Float.self), frames: Int(b.mDataByteSize) / (4 * ch), channels: ch)
}
AudioDeviceStart(agg, tapProc)

// Optional microphone.
var micID: AudioObjectID?
var micProc: AudioDeviceIOProcID?
let micWindow = Window()
var micFormat = IOFormat(rate: 0, channels: 1)
var micState = "off"
let micUID = opt("--mic-uid")
let micAfter = Double(opt("--mic-after") ?? "0") ?? 0
let micIfHFP = args.contains("--mic-if-hfp")
func openMic() {
    guard let uid = micUID else { return }
    var a = addr(kAudioHardwarePropertyTranslateUIDToDevice); var cf = uid as CFString
    var id = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id) }
    guard st == noErr, id != kAudioObjectUnknown else { micState = "not_found"; return }
    if micIfHFP, let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice), rate(out) > 24_000 { micState = "skipped_not_hfp"; return }
    micFormat = streamFormat(id, scope: kAudioObjectPropertyScopeInput)
    AudioDeviceCreateIOProcIDWithBlock(&micProc, id, queue) { _, input, _, _, _ in
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let b = abl.first, let data = b.mData else { return }
        let ch = Int(b.mNumberChannels); guard ch > 0 else { return }
        micWindow.add(data.assumingMemoryBound(to: Float.self), frames: Int(b.mDataByteSize) / (4 * ch), channels: ch)
    }
    micState = AudioDeviceStart(id, micProc) == noErr ? "on" : "start_failed"
    micID = id
}

let t0 = Date().timeIntervalSince1970
var stopping = false
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let sigs = [SIGTERM, SIGINT].map { s -> DispatchSourceSignal in
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main); src.setEventHandler { stopping = true }; src.resume(); return src
}
_ = sigs
while !stopping && Date().timeIntervalSince1970 - t0 < secs {
    Thread.sleep(forTimeInterval: 0.5)
    let now = Date().timeIntervalSince1970
    if micUID != nil, micState == "off", now - t0 >= micAfter { openMic() }
    let (ts, tcb) = tapWindow.take()
    var line = summarize(ts, tcb, sr: tapRate, freqs: freqs, prefix: "tap_")
    line["t"] = (now * 1000).rounded() / 1000
    if let o = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
        line["out_transport"] = transport(o); line["out_rate"] = rate(o); line["out_running"] = running(o)
    }
    if let i = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) {
        line["in_transport"] = transport(i); line["in_rate"] = rate(i); line["in_running"] = running(i)
    }
    line["mic_state"] = micState
    if micState == "on" {
        let (ms, mcb) = micWindow.take()
        for (k, v) in summarize(ms, mcb, sr: micFormat.rate, freqs: freqs, prefix: "mic_") { line[k] = v }
    }
    out.write((emit(line) + "\n").data(using: .utf8)!)
    RunLoop.current.run(until: Date())   // deliver signal handlers on main
}
if let micID, let micProc { AudioDeviceStop(micID, micProc); AudioDeviceDestroyIOProcID(micID, micProc) }
AudioDeviceStop(agg, tapProc); AudioDeviceDestroyIOProcID(agg, tapProc!)
AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
out.closeFile()
