// MicHotSwap — 指定 UID のマイクで録音し、抜き差しされても同じ WAV に追記し続けるスパイク（計画 00 Task 4）。
//
// 使い方: .build/debug/MicHotSwap --uid <deviceUID> --out path.wav [--vpio] [--seconds N]
//   --seconds を省くと Ctrl-C まで録る。終了時に総フレーム数・秒数・lost/resumed の回数を出す。
//   2 秒ごとに `level` 行（直近 2 秒の RMS dBFS と累計フレーム）を出す。無音・停止の判定に使う。
//
// 処理（計画 02 の「猶予中の処理」が参照する）:
//   1. UID → AudioDeviceID: kAudioHardwarePropertyTranslateUIDToDevice（qualifier に UID の CFString）。
//      UID が存在しないときは kAudioObjectUnknown(0) が返る（status は noErr）。
//   2. AVAudioEngine を作る → (--vpio なら inputNode.setVoiceProcessingEnabled(true)) →
//      inputNode.audioUnit に kAudioOutputUnitProperty_CurrentDevice で AudioDeviceID を設定 →
//      inputNode.outputFormat(forBus: 0) で installTap → prepare → start。
//      VPIO は IO ユニットを差し替えるので、デバイス設定より先に有効にする。
//   3. kAudioHardwarePropertyDevices の変化を監視。指定 UID が消えたら engine.stop() + removeTap して破棄、「lost」。
//      戻ったらエンジンを新しく作り直して同じ AVAudioFile に追記、「resumed after N 秒」。
//      戻った直後は入力ストリームが未準備のことがあるので、失敗したら 0.5 秒おきに最大 20 回やり直す。
//   4. AVAudioFile は最初に開いたものを最後まで保持する（close しないと WAV のヘッダが確定しない。Task 3 の実測）。
//      再作成後にフォーマット（サンプルレート・チャンネル数）が変わったら AVAudioConverter で最初のフォーマットに合わせる。
//   - 猶予中（lost〜resumed）の無音は書かない（スパイク。要件書 §11.5 では本体が無音を書く）。
//   - main.swift のトップレベルのクロージャは @MainActor に推論され、音声スレッドから呼ばれると SIGILL になる
//     （Task 3 の実測）。ブロックはすべて HotSwap クラスのメソッド内で作る。
//
// 実測（Intel x86_64 / macOS 26.6.2、2026-10-25）:
//   - マイク許可ダイアログ（TCC の責任プロセスは起動元の Orca.app）が未応答の間、AVAudioEngine.inputNode への
//     アクセス自体が止まった（約 16 分。AVAudioIOUnit の BindToDeviceInternal が HAL の mach_msg 待ち）。
//     その後の engine.start() も 6 分止まり、PerformCommand(*ioNode, kAUStartIO) が
//     268435460（0x10000004 = MACH_SEND_TIMED_OUT）で失敗した。エラーは返らず止まるだけ。
//     → 計画 02 では AVCaptureDevice.authorizationStatus(for: .audio) を確認し、requestAccess を済ませてからエンジンを組む。
//   - 許可後: 内蔵マイク（BuiltInMicrophoneDevice、1 ch / 48000 Hz / Float32）で 5 秒録って WAV ができた。
//   - 抜き差し中の復帰（lost / resumed）と --vpio は未確認（docs/superpowers/research/2026-10-24-spike-results.md 項目 5・10）。

@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - 引数

var uid: String?
var outPath = "/tmp/hotswap.wav"
var vpio = false
var seconds: Double?
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--uid": uid = args.next()
        case "--out": outPath = args.next() ?? outPath
        case "--vpio": vpio = true
        case "--seconds": seconds = Double(args.next() ?? "")
        default:
            FileHandle.standardError.write("unknown argument: \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
}
guard let uid else {
    FileHandle.standardError.write("usage: MicHotSwap --uid <deviceUID> --out path.wav [--vpio] [--seconds N]\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - ヘルパー

@Sendable nonisolated func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

@Sendable nonisolated func say(_ s: String) { print("[\(ts())] \(s)") }

nonisolated func deviceID(forUID uid: String) -> AudioObjectID {
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = withUnsafePointer(to: &cfUID) { p in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
    }
    return st == noErr ? id : AudioObjectID(kAudioObjectUnknown)
}

nonisolated func deviceName(_ id: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let r = ref else { return "?" }
    return r.takeRetainedValue() as String
}

struct SetupError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - 録音の本体

final class HotSwap: @unchecked Sendable {
    let uid: String
    let outURL: URL
    let vpio: Bool
    // 制御（エンジンの作成・破棄、状態の変更）はすべて ctl の上で行う
    let ctl = DispatchQueue(label: "MicHotSwap.ctl")
    var engine: AVAudioEngine?
    var lostAt: Date?
    var lostCount = 0
    var resumeCount = 0
    var retryLeft = 0
    var configObserver: NSObjectProtocol?

    // 書き込み側（tap のスレッドから）は lock で守る
    let lock = NSLock()
    var file: AVAudioFile?
    var converter: AVAudioConverter?
    var framesWritten: Int64 = 0
    var sumSq: Double = 0
    var sampleCount: Int64 = 0
    var writeError: Error?

    init(uid: String, outURL: URL, vpio: Bool) {
        self.uid = uid
        self.outURL = outURL
        self.vpio = vpio
    }

    // MARK: 書き込み

    func write(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        var out = buf
        if !buf.format.isEqual(file.processingFormat) {
            // フォーマットが変わったとき（再接続後のサンプルレート違いなど）だけ変換する
            if converter == nil || !(converter!.inputFormat.isEqual(buf.format)) {
                converter = AVAudioConverter(from: buf.format, to: file.processingFormat)
                say("format changed: \(buf.format) -> converting to \(file.processingFormat)")
            }
            guard let conv = converter else { return }
            let ratio = file.processingFormat.sampleRate / buf.format.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
            guard let o = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) else { return }
            nonisolated(unsafe) var fed = false
            nonisolated(unsafe) let inBuf = buf
            var err: NSError?
            conv.convert(to: o, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            if let err { writeError = err; return }
            out = o
        }
        if let ch = out.floatChannelData {
            let n = Int(out.frameLength)
            for c in 0..<Int(out.format.channelCount) {
                let p = ch[c]
                for i in 0..<n { let v = Double(p[i]); sumSq += v * v }
            }
            sampleCount += Int64(n * Int(out.format.channelCount))
        }
        do {
            try file.write(from: out)
            framesWritten += Int64(out.frameLength)
        } catch { writeError = error }
    }

    func makeTapBlock() -> AVAudioNodeTapBlock {
        return { [self] buf, _ in write(buf) }
    }

    // MARK: エンジン

    /// ctl の上で呼ぶ。成功したら engine を保持する。
    func buildEngine() throws {
        let devID = deviceID(forUID: uid)
        guard devID != kAudioObjectUnknown else { throw SetupError(description: "UID not found: \(uid)") }
        let e = AVAudioEngine()
        let input = e.inputNode
        if vpio {
            try input.setVoiceProcessingEnabled(true)
            say("voice processing enabled: \(input.isVoiceProcessingEnabled)")
        }
        guard let au = input.audioUnit else { throw SetupError(description: "inputNode.audioUnit is nil") }
        var dev = devID
        let st = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else { throw SetupError(description: "set CurrentDevice failed: status=\(st)") }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw SetupError(description: "input format not ready: \(fmt)")
        }
        say("device: id=\(devID) name=\(deviceName(devID)) format=\(fmt)")

        lock.lock()
        if file == nil {
            try? FileManager.default.removeItem(at: outURL)
            do {
                file = try AVAudioFile(
                    forWriting: outURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                say("file opened: \(outURL.path) processingFormat=\(file!.processingFormat)")
            } catch {
                lock.unlock()
                throw error
            }
        }
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: fmt, block: makeTapBlock())
        e.prepare()
        do {
            try e.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = e
        observeConfigChange(e)
    }

    func teardownEngine() {
        guard let e = engine else { return }
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        e.stop()
        e.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    func observeConfigChange(_ e: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: nil
        ) { [self] _ in
            ctl.async { [self] in
                say("AVAudioEngineConfigurationChange (isRunning=\(engine?.isRunning ?? false))")
            }
        }
    }

    // MARK: 監視

    func start() {
        ctl.sync {
            do {
                try buildEngine()
                say("recording (uid=\(uid) vpio=\(vpio))")
            } catch {
                say("ERROR start: \(error)")
                exit(1)
            }
        }
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, ctl) { [self] _, _ in
            devicesChanged()
        }
        startLevelTimer()
    }

    func devicesChanged() {
        let present = deviceID(forUID: uid) != kAudioObjectUnknown
        if !present, engine != nil {
            teardownEngine()
            lostAt = Date()
            lostCount += 1
            say("lost (uid=\(uid))")
        } else if present, engine == nil, lostAt != nil, retryLeft == 0 {
            retryLeft = 20
            tryResume()
        } else {
            say("devices changed (uid present=\(present), engine=\(engine != nil ? "running" : "nil"))")
        }
    }

    func tryResume() {
        guard engine == nil, let lostAt else { retryLeft = 0; return }
        do {
            try buildEngine()
            let secs = Date().timeIntervalSince(lostAt)
            resumeCount += 1
            retryLeft = 0
            self.lostAt = nil
            say(String(format: "resumed after %.1f 秒", secs))
        } catch {
            retryLeft -= 1
            say("resume failed (\(error)); retries left=\(retryLeft)")
            teardownEngine()
            if retryLeft > 0 {
                ctl.asyncAfter(deadline: .now() + 0.5) { [self] in tryResume() }
            }
        }
    }

    var lastFrames: Int64 = 0
    var timer: DispatchSourceTimer?
    func startLevelTimer() {
        let t = DispatchSource.makeTimerSource(queue: ctl)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [self] in
            lock.lock()
            let rms = sampleCount > 0 ? (sumSq / Double(sampleCount)).squareRoot() : 0
            let frames = framesWritten
            sumSq = 0; sampleCount = 0
            lock.unlock()
            let db = rms > 0 ? String(format: "%.1f", 20 * log10(rms)) : "-inf"
            say("level rms=\(db) dBFS +frames=\(frames - lastFrames) total=\(frames) state=\(engine == nil ? "lost" : "recording")")
            lastFrames = frames
        }
        t.resume()
        timer = t
    }

    // MARK: 終了

    func finish() -> Never {
        teardownEngine()
        lock.lock()
        let sr = file?.processingFormat.sampleRate ?? 0
        let frames = framesWritten
        if let e = writeError { say("write error: \(e)") }
        file?.close()
        lock.unlock()
        say("done: frames=\(frames) (\(String(format: "%.2f", sr > 0 ? Double(frames) / sr : 0)) s) lost=\(lostCount) resumed=\(resumeCount)")
        say("wrote \(outURL.path)")
        exit(0)
    }

    // SIGINT は別キューで受ける。最初のエンジン起動が終わる前（マイク許可ダイアログ待ちで inputNode が
    // ブロックしている間など。実測）は ctl が塞がっているので、その場で終了する。
    let sigQueue = DispatchQueue(label: "MicHotSwap.signal")
    nonisolated(unsafe) var started = false
    var sigSource: DispatchSourceSignal?
    func installSigint() {
        signal(SIGINT, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: sigQueue)
        s.setEventHandler { [self] in
            if started {
                ctl.async { [self] in finish() }
            } else {
                say("interrupted before the engine started (microphone permission pending?)")
                exit(1)
            }
        }
        s.resume()
        sigSource = s
    }

    func installTimer(seconds: Double?) {
        started = true
        if let seconds {
            ctl.asyncAfter(deadline: .now() + seconds) { [self] in finish() }
        }
    }
}

let hs = HotSwap(uid: uid, outURL: URL(fileURLWithPath: outPath), vpio: vpio)
hs.installSigint()
hs.start()
hs.installTimer(seconds: seconds)
dispatchMain()
