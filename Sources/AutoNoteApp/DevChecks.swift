// DevChecks — 計画 02 Task 1 の TCC 確認用の一時コード。計画 06 の Task 13 で削除する。
//
// `.app` の中から呼ぶ理由: TCC の責任プロセスは起動元で決まる。ターミナルから CLI を打つと
// ターミナルの許可を見てしまうので、`open` で起動した com.yutaokoshi.autonote の許可を確かめるにはここで呼ぶ。
// `open` 起動では標準出力が見えないので、結果は <logsDirectory>/dev-checks.log に 1 行ずつ追記する。
//
// 手順は Spikes/Sources/TapCapture/main.swift（process tap）と
// Spikes/Sources/AppleSpeechProbe/main.swift の dictation --file 経路を写したもの。

@preconcurrency import AVFoundation
import AutoNoteCore
import CoreAudio
import Darwin
import Foundation
@preconcurrency import Speech
import Synchronization

/// `nonisolated`: IOProc のブロックを MainActor 文脈で作ると IO スレッドで SIGILL になる（スパイク項目 3）。
nonisolated enum DevChecks {
    enum AggregateLayout: String, Sendable {
        /// 出力デバイスを含めない（MainSubDevice / SubDeviceList なし）
        case tapOnly
        /// スパイクと同じ。既定の出力デバイスを MainSubDevice に入れる
        case withOutputClock
    }

    static let maxSeconds = 120
    static let maxGaps = 16

    // MARK: - システム音声

    static func checkSystemAudio(seconds: Int = 15) async {
        let secs = max(1, min(seconds, maxSeconds))
        log("system start seconds=\(secs)")
        let callbacks = await capture(layout: .tapOnly, seconds: secs)
        if callbacks == 0 {
            log("system tapOnly callbacks=0 → withOutputClock で取り直す")
            _ = await capture(layout: .withOutputClock, seconds: secs)
        }
        log("system end")
    }

    /// IOProc から書く集計。IOProc は 1 本の直列キューから呼ばれるので、固定長領域の書き手は常に 1 つ。
    /// 読むのは IOProc を止めて破棄が終わった後（または打ち切り後の参考値）だけ。
    final class Stats: @unchecked Sendable {
        let callbacks = Atomic<Int>(0)
        let frames = Atomic<Int>(0)
        let perSecond: UnsafeMutablePointer<Int>
        let peak: UnsafeMutablePointer<Float>  // [0] = 最大の絶対値
        let gapHost: UnsafeMutablePointer<Double>
        let gapSample: UnsafeMutablePointer<Double>
        let gapCount = Atomic<Int>(0)
        let last: UnsafeMutablePointer<UInt64>  // [0] = 前回の mHostTime（0 = 未受信）
        let lastSample: UnsafeMutablePointer<Double>
        let startHost: UInt64
        let secondsPerTick: Double
        let channels: Int
        let slots: Int

        init(startHost: UInt64, channels: Int, slots: Int) {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            secondsPerTick = Double(tb.numer) / Double(tb.denom) / 1_000_000_000
            self.startHost = startHost
            self.channels = max(1, channels)
            self.slots = slots
            perSecond = .allocate(capacity: slots); perSecond.initialize(repeating: 0, count: slots)
            peak = .allocate(capacity: 1); peak.initialize(to: 0)
            gapHost = .allocate(capacity: DevChecks.maxGaps); gapHost.initialize(repeating: 0, count: DevChecks.maxGaps)
            gapSample = .allocate(capacity: DevChecks.maxGaps); gapSample.initialize(repeating: 0, count: DevChecks.maxGaps)
            last = .allocate(capacity: 1); last.initialize(to: 0)
            lastSample = .allocate(capacity: 1); lastSample.initialize(to: 0)
        }

        deinit {
            perSecond.deallocate(); peak.deallocate(); gapHost.deallocate(); gapSample.deallocate()
            last.deallocate(); lastSample.deallocate()
        }

        /// IO スレッドから呼ばれる。ロック・確保・ファイル書き込みをしない。
        func consume(_ abl: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
            callbacks.add(1, ordering: .relaxed)
            let host = time.pointee.mHostTime
            let sample = time.pointee.mSampleTime
            if host > startHost {
                let idx = Int(Double(host - startHost) * secondsPerTick)
                if idx >= 0, idx < slots { perSecond[idx] += 1 }
            }
            let prev = last.pointee
            if prev != 0, host > prev {
                let dt = Double(host - prev) * secondsPerTick
                if dt >= 0.1 {
                    let n = gapCount.load(ordering: .relaxed)
                    if n < DevChecks.maxGaps {
                        gapHost[n] = dt
                        gapSample[n] = sample - lastSample.pointee
                        gapCount.store(n + 1, ordering: .relaxed)
                    }
                }
            }
            last.pointee = host
            lastSample.pointee = sample

            // tap の形式（チャンネル数）に合う最後のバッファを読む（withOutputClock で出力デバイスの入力が混ざっても tap を選ぶ）
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            var chosen: AudioBuffer?
            for b in list where Int(b.mNumberChannels) == channels { chosen = b }
            guard let buf = chosen ?? list.last, let data = buf.mData else { return }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let ch = max(1, Int(buf.mNumberChannels))
            frames.add(count / ch, ordering: .relaxed)
            let p = data.assumingMemoryBound(to: Float.self)
            var m = peak.pointee
            for i in 0..<count {
                let v = abs(p[i])
                if v > m { m = v }
            }
            peak.pointee = m
        }
    }

    /// 1 回取る。戻り値は callbacks。
    static func capture(layout: AggregateLayout, seconds: Int) async -> Int {
        // 1-2. tap
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "AutoNote DevChecks"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { log("system layout=\(layout.rawValue) error=AudioHardwareCreateProcessTap status=\(fourCC(st))"); return 0 }
        let tapUUID = desc.uuid.uuidString

        // 3. 受信フォーマット
        let (fst, asbd) = getProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard fst == noErr else {
            log("system layout=\(layout.rawValue) error=kAudioTapPropertyFormat status=\(fourCC(fst))")
            _ = AudioHardwareDestroyProcessTap(tapID)
            return 0
        }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        log("system layout=\(layout.rawValue) format sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) nonInterleaved=\(nonInterleaved)")

        // 4. 既定の出力デバイス（記録用。withOutputClock では aggregate に入れる）
        let (ost, outputID) = getProperty(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
        var outputUID = ""
        if ost == noErr {
            let (ust, uid) = getProperty(outputID, kAudioDevicePropertyDeviceUID, "" as CFString)
            if ust == noErr { outputUID = uid as String }
        }
        log("system layout=\(layout.rawValue) output_uid=\(maskBluetooth(outputUID))")

        // 5. aggregate
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AutoNote DevChecks",
            kAudioAggregateDeviceUIDKey: "com.yutaokoshi.autonote.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID]],
        ]
        if layout == .withOutputClock {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var aggID = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard st == noErr else {
            log("system layout=\(layout.rawValue) error=AudioHardwareCreateAggregateDevice status=\(fourCC(st))")
            _ = AudioHardwareDestroyProcessTap(tapID)
            return 0
        }

        // 6. IOProc
        let stats = Stats(startHost: mach_absolute_time(), channels: Int(asbd.mChannelsPerFrame), slots: seconds + 2)
        let ioQueue = DispatchQueue(label: "com.yutaokoshi.autonote.devchecks.io", qos: .userInteractive)
        var procID: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue, makeIOBlock(stats))
        guard st == noErr, let procID else {
            log("system layout=\(layout.rawValue) error=AudioDeviceCreateIOProcIDWithBlock status=\(fourCC(st))")
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            return 0
        }

        // 7. 開始（初回はここで「システム音声の録音」許可が求められる）
        st = AudioDeviceStart(aggID, procID)
        log("system layout=\(layout.rawValue) AudioDeviceStart status=\(fourCC(st))")
        if st == noErr { try? await Task.sleep(for: .seconds(seconds)) }

        // 8. 破棄は専用キューで行い、10 秒で打ち切る
        let finished = await teardown(layout: layout, aggID: aggID, procID: procID, tapID: tapID, started: st == noErr, timeout: 10)
        if !finished { log("system layout=\(layout.rawValue) teardown timeout") }

        let callbacks = stats.callbacks.load(ordering: .relaxed)
        let frames = stats.frames.load(ordering: .relaxed)
        let peak = stats.peak.pointee
        let peakDB = peak > 0 ? String(format: "%.2f", 20 * log10(Double(peak))) : "-inf"
        let perSecond = (0..<seconds).map { String(stats.perSecond[$0]) }.joined(separator: ",")
        let gaps = (0..<stats.gapCount.load(ordering: .relaxed)).map {
            "{host_s:\(String(format: "%.3f", stats.gapHost[$0])), sample_frames:\(Int(stats.gapSample[$0]))}"
        }.joined(separator: ", ")
        log("system layout=\(layout.rawValue) callbacks=\(callbacks) frames=\(frames) peak_dbfs=\(peakDB) per_second=[\(perSecond)] gaps=[\(gaps)]")
        return callbacks
    }

    static func makeIOBlock(_ stats: Stats) -> AudioDeviceIOBlock {
        { _, inInputData, inInputTime, _, _ in stats.consume(inInputData, inInputTime) }
    }

    /// 破棄を専用キューで行う。`timeout` 秒で終わらなければ false（破棄はキュー上で続く）。
    static func teardown(layout: AggregateLayout, aggID: AudioObjectID, procID: AudioDeviceIOProcID, tapID: AudioObjectID,
                         started: Bool, timeout: Double) async -> Bool {
        let once = Once()
        let queue = DispatchQueue(label: "com.yutaokoshi.autonote.devchecks.teardown")
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                var steps: [String] = []
                if started { steps.append("stop=\(fourCC(AudioDeviceStop(aggID, procID)))") }
                steps.append("destroyIOProc=\(fourCC(AudioDeviceDestroyIOProcID(aggID, procID)))")
                steps.append("destroyAggregate=\(fourCC(AudioHardwareDestroyAggregateDevice(aggID)))")
                steps.append("destroyTap=\(fourCC(AudioHardwareDestroyProcessTap(tapID)))")
                log("system layout=\(layout.rawValue) teardown \(steps.joined(separator: " "))")
                if once.fire() { c.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.fire() { c.resume(returning: false) }
            }
        }
    }

    // MARK: - Dictation

    /// 音声認識の許可は要求しない（`requestAuthorization` を呼ばない）。DictationTranscriber が許可なしで動くかを見る。
    static func checkDictation(file: URL) async {
        let auth = SFSpeechRecognizer.authorizationStatus()
        log("dictation start file=\(file.path) authorizationStatus=\(auth.rawValue)（0=未決定 1=拒否 2=制限 3=許可）")
        do {
            let t0 = Date()
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja_JP")) else {
                log("dictation error=DictationTranscriber が ja_JP に対応していない")
                return
            }
            let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log("dictation 資産の取得を開始")
                try await req.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collector = Task { () async throws -> [String] in
                var parts: [String] = []
                for try await r in transcriber.results where r.isFinal { parts.append(String(r.text.characters)) }
                return parts
            }
            let audio = try AVAudioFile(forReading: file)
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await collector.value.joined()
            let after = SFSpeechRecognizer.authorizationStatus()
            log("dictation ok locale=\(locale.identifier) elapsed_s=\(String(format: "%.2f", Date().timeIntervalSince(t0))) chars=\(text.count) authorizationStatus_after=\(after.rawValue) text=\(String(text.prefix(100)))")
        } catch {
            log("dictation error=\(error)")
        }
    }

    // MARK: - 補助

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    static func getProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> (OSStatus, T) {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        return (st, value)
    }

    static func fourCC(_ status: OSStatus) -> String {
        guard status != noErr else { return "0" }
        let s = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { b in
            String(b.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "?" })
        }
        return "\(status)('\(s)')"
    }

    /// Bluetooth の UID（MAC アドレス）の下 3 オクテットを伏せる。
    static func maskBluetooth(_ s: String) -> String {
        let h = "[0-9A-Fa-f]{2}"
        return s.replacingOccurrences(
            of: "(\(h)[-:]\(h)[-:]\(h))[-:]\(h)[-:]\(h)[-:]\(h)", with: "$1-xx-xx-xx", options: .regularExpression)
    }

    private static let logLock = NSLock()

    static func log(_ line: String) {
        let dir = AppPaths.standard.logsDirectory
        let url = dir.appending(path: "dev-checks.log")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let stamp = f.string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        logLock.lock(); defer { logLock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
