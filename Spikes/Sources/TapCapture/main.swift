// TapCapture — Core Audio process tap で全システム音を受信して WAV に書くスパイク（計画 00 Task 3）。
//
// 使い方: swift run TapCapture [--seconds N] [--out path.wav]
//   既定は 10 秒、/tmp/tap.wav。終了時に総フレーム数と RMS（dBFS）を出す。
//
// 動いた呼び出し手順（計画 02 が参照する）:
//   1. CATapDescription(stereoGlobalTapButExcludeProcesses: [])  … 全システム音（除外なし）
//      isPrivate = true, muteBehavior = .unmuted。tap の UUID は desc.uuid。
//   2. AudioHardwareCreateProcessTap(desc, &tapID)
//   3. kAudioTapPropertyFormat を tapID から読む → AudioStreamBasicDescription（受信フォーマット）
//   4. 既定の出力デバイスの UID を取る（kAudioHardwarePropertyDefaultSystemOutputDevice → kAudioDevicePropertyDeviceUID）
//   5. AudioHardwareCreateAggregateDevice(dict, &aggID)。dict は
//        kAudioAggregateDeviceNameKey / UIDKey（毎回新しい UUID）/ IsPrivateKey = true / IsStackedKey = false
//        kAudioAggregateDeviceTapAutoStartKey = true
//        kAudioAggregateDeviceMainSubDeviceKey = 出力デバイス UID
//        kAudioAggregateDeviceSubDeviceListKey = [[kAudioSubDeviceUIDKey: 出力デバイス UID]]
//        kAudioAggregateDeviceTapListKey = [[kAudioSubTapUIDKey: tap UUID, kAudioSubTapDriftCompensationKey: true]]
//   6. AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { inInputData を読む }
//   7. AudioDeviceStart(aggID, procID) … 初回はここで「システム音声の録音」許可が求められる
//   8. N 秒後 AudioDeviceStop → AudioDeviceDestroyIOProcID → AudioHardwareDestroyAggregateDevice
//      → AudioHardwareDestroyProcessTap の順で破棄
//
// 実測（Intel x86_64 / macOS 26.6.2 / 内蔵スピーカー、2026-10-24）:
//   - 受信フォーマット: 48000 Hz / 2ch / Float32 / interleaved（kAudioTapPropertyFormat の値そのまま）
//   - 許可あり + afplay 再生中 5 秒: callbacks=461, frames=236032（4.92 s）, rms=-31.72 dBFS。WAV も同値。
//   - 許可ありでも、どのプロセスも音を出していない間は IOProc が呼ばれない（callbacks=0, frames=0）。
//     無音は「ゼロのサンプルが届く」のではなく「コールバックが来ない」形で現れる。
//   - 許可ダイアログが未応答の間: 全 API が status 0 を返し、callbacks=0。AudioDeviceDestroyIOProcID が約 3 分ブロックした。
//   - main.swift のトップレベルに書いたクロージャは @MainActor に推論され、IO スレッドで SIGILL（makeIOBlock 参照）。
//   - TCC の責任プロセスは起動元アプリ（今回は Orca.app = com.stablyai.orca）。
//   - 許可なし時の挙動は本スパイクでは再現できなかった（未確定）:
//     (a) Orca で許可をオフ → 同じ系統から実行: tccd は authValue=0、coreaudiod は "Client is not granted access to the tap."
//         を出したが、全 API が status 0 で音声も届いた（rms=-31.74 dBFS）。
//     (b) 許可状態が未確認の Terminal.app から実行: ダイアログなしで届いた（frames=235520, rms=-31.71 dBFS）。
//     → 自己署名 .app 単体・再起動後に計画 02 の最初のタスクで再確認する。許可なしは API エラーで検知できない前提で設計する。
//   ※ 許可なし時の挙動などは docs/superpowers/research/2026-10-24-spike-results.md 項目 3。

import AVFoundation
import CoreAudio
import Foundation

// パイプ越しでも行ごとに出力が見えるようにする（TCC 待ちで止まったときの位置が分かる）
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - 引数

var seconds: Double = 10
var outPath = "/tmp/tap.wav"
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--seconds": seconds = Double(args.next() ?? "") ?? seconds
        case "--out": outPath = args.next() ?? outPath
        default:
            FileHandle.standardError.write("unknown argument: \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
}

func check(_ status: OSStatus, _ what: String) {
    guard status == noErr else {
        let fourCC = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { b in
            String(b.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "?" })
        }
        print("ERROR \(what): status=\(status) ('\(fourCC)')")
        exit(1)
    }
    print("ok: \(what)")
}

func getProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> (OSStatus, T) {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    // CFString の取得にも使う。スパイクなので参照カウントの厳密さ（+1 で返る分のリーク）は気にしない。
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
    return (st, value)
}

// MARK: - 1-2. tap

let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.name = "AutoNote TapCapture spike"
desc.isPrivate = true
desc.muteBehavior = .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap (tapID=\(tapID))")
let tapUUID = desc.uuid.uuidString

// MARK: - 3. 受信フォーマット

let (fmtStatus, asbdValue) = getProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
check(fmtStatus, "kAudioTapPropertyFormat")
var asbd = asbdValue
let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
print("format: sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) float=\(isFloat) nonInterleaved=\(isNonInterleaved) formatID=\(asbd.mFormatID == kAudioFormatLinearPCM ? "lpcm" : String(asbd.mFormatID))")
guard let avFormat = AVAudioFormat(streamDescription: &asbd) else {
    print("ERROR: AVAudioFormat(streamDescription:) failed"); exit(1)
}

// MARK: - 4. 既定の出力デバイス

let (outStatus, outputID) = getProperty(
    AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
check(outStatus, "default system output device (id=\(outputID))")
let (uidStatus, outputUIDRef) = getProperty(outputID, kAudioDevicePropertyDeviceUID, "" as CFString)
check(uidStatus, "output device UID")
let outputUID = outputUIDRef as String
print("output device UID: \(outputUID)")

// MARK: - 5. aggregate device

let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "AutoNote TapCapture",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID), "AudioHardwareCreateAggregateDevice (aggID=\(aggID))")

// MARK: - 6. 出力ファイルと集計

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
let file: AVAudioFile
do {
    file = try AVAudioFile(
        forWriting: url, settings: avFormat.settings, commonFormat: .pcmFormatFloat32,
        interleaved: avFormat.isInterleaved)
} catch {
    print("ERROR AVAudioFile(forWriting:): \(error)"); exit(1)
}

// IOProc は専用キューから呼ばれる。スパイクなので状態は NSLock で守るだけにして
// Sendable 検査は @unchecked で逃がす（AVAudioFile が Sendable でないため）。
final class Capture: @unchecked Sendable {
    let lock = NSLock()
    let file: AVAudioFile
    let format: AVAudioFormat
    var frames: Int64 = 0
    var sumSquares: Double = 0
    var samples: Int64 = 0
    var callbacks = 0
    var writeError: Error?
    init(file: AVAudioFile, format: AVAudioFormat) { self.file = file; self.format = format }

    func consume(_ abl: UnsafePointer<AudioBufferList>) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl, deallocator: nil),
            buf.frameLength > 0
        else { return }
        frames += Int64(buf.frameLength)
        if let ch = buf.floatChannelData {
            let n = Int(buf.frameLength)
            let chCount = format.isInterleaved ? 1 : Int(format.channelCount)
            let perCh = format.isInterleaved ? n * Int(format.channelCount) : n
            for c in 0..<chCount {
                let p = ch[c]
                for i in 0..<perCh { let v = Double(p[i]); sumSquares += v * v }
                samples += Int64(perCh)
            }
        }
        do { try file.write(from: buf) } catch { writeError = error }
    }
}
let capture = Capture(file: file, format: avFormat)

// 重要: main.swift のトップレベルで書いたクロージャは @MainActor に推論され、Swift 6 では
// IO スレッドから呼ばれた瞬間に実行時の隔離チェック（dispatch_assert_queue）で SIGILL になる（実測）。
// nonisolated な関数の中でブロックを作り、MainActor から切り離す。
nonisolated func makeIOBlock(_ capture: Capture) -> AudioDeviceIOBlock {
    return { _, inInputData, _, _, _ in capture.consume(inInputData) }
}

let queue = DispatchQueue(label: "TapCapture.io", qos: .userInteractive)
var procID: AudioDeviceIOProcID?
check(
    AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue, makeIOBlock(capture)),
    "AudioDeviceCreateIOProcIDWithBlock")

// MARK: - 7. 開始 → N 秒待つ → 停止・破棄

check(AudioDeviceStart(aggID, procID), "AudioDeviceStart")
print("capturing \(seconds) s ...")
Thread.sleep(forTimeInterval: seconds)

check(AudioDeviceStop(aggID, procID), "AudioDeviceStop")
check(AudioDeviceDestroyIOProcID(aggID, procID!), "AudioDeviceDestroyIOProcID")
check(AudioHardwareDestroyAggregateDevice(aggID), "AudioHardwareDestroyAggregateDevice")
check(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")

capture.lock.lock()
let rms = capture.samples > 0 ? (capture.sumSquares / Double(capture.samples)).squareRoot() : 0
let dbfs = rms > 0 ? 20 * log10(rms) : -Double.infinity
print("callbacks=\(capture.callbacks)")
print("frames=\(capture.frames) (\(String(format: "%.2f", Double(capture.frames) / asbd.mSampleRate)) s)")
print("rms=\(String(format: "%.2f", dbfs)) dBFS")
if let e = capture.writeError { print("write error: \(e)") }
// グローバルの AVAudioFile は exit まで deinit されず、close しないと WAV のヘッダとデータが確定しない（実測: audio bytes 0）。
capture.file.close()
capture.lock.unlock()
print("wrote \(outPath)")
