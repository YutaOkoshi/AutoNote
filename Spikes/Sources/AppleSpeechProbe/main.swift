// AppleSpeechProbe — Apple の音声認識（DictationTranscriber / SFSpeechRecognizer / SpeechTranscriber）を
// 日本語で試すスパイク（計画 00 Task 6）。使い捨てのコード。
//
// 使い方:
//   AppleSpeechProbe --engine dictation|sf --file path.wav [--ref ref.txt] [--locale ja-JP] [--contextual "語1,語2"] [--seconds N]
//   AppleSpeechProbe --engine dictation|sf --live [--locale ja-JP] [--contextual "語1,語2"] [--seconds N]
//   AppleSpeechProbe --engine transcriber [--locale ja-JP]
//
//   --file     経過秒・RTF（経過秒 ÷ 音声秒）・CER（scripts/cer.py を python3 -I で呼ぶ。--ref があるとき）・先頭 200 文字を出す。
//              --seconds N を付けると先頭 N 秒だけを一時 WAV に切り出して使う（短い動作確認用。CER は意味を持たない）。
//              認識結果の全文は $TMPDIR/AppleSpeechProbe-<engine>-hyp.txt に書く（コミットしない）。
//   --live     既定の入力デバイスから AVAudioEngine で取り、部分結果を `[+秒] 部分:`、確定を `[+秒] 確定:` で出す。
//              Ctrl-C か --seconds N で止める。dictation の行末の (音声 ~X.Xs) は結果が覆う音声の末尾時刻。
//              [+秒] との差が「話してから文字になるまでの遅れ」の目安。
//   --engine transcriber  SpeechTranscriber の isAvailable と supportedLocales を出して終わる（機材・許可は不要）。
//
// API（Swift 6.3.2 / macOS 26.5 SDK でコンパイルして確かめた。2026-10-25）:
//   - contextual strings は transcriber モジュールではなく SpeechAnalyzer 側にある:
//       let ctx = AnalysisContext(); ctx.contextualStrings[.general] = ["語"]; try await analyzer.setContext(ctx)
//     （SpeechAnalyzer.init(inputSequence:modules:options:analysisContext:...) でも渡せる）。
//     DictationTranscriber / SpeechTranscriber に contextualStrings メンバーは無い（コンパイルエラー）。
//     SFSpeechRecognizer は従来どおり SFSpeechRecognitionRequest.contextualStrings。
//   - DictationTranscriber には isAvailable が無い（SpeechTranscriber にはある）。supportedLocales で判定する。
//   - DictationTranscriber.ContentHint（.farField など）は SpeechTranscriber には無い。
//   - モデル資産: AssetInventory.status(forModules:) → assetInstallationRequest(supporting:) が nil でなければ downloadAndInstall()。
//
// Swift 6 の注意（MicHotSwap と同じ）: main.swift のトップレベルのクロージャは @MainActor に推論され、
// 音声スレッドや認識のコールバックから呼ばれると SIGILL になる。ブロックはすべて Probe / MicCapture の中で作る。

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import Speech

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - 引数

struct Options: Sendable {
    var engine = ""
    var file: String?
    var live = false
    var locale = "ja-JP"
    var contextual: [String] = []
    var ref: String?
    var seconds: Double?
}

let usage = """
usage: AppleSpeechProbe --engine dictation|sf|transcriber (--file path.wav | --live) [--locale ja-JP] \
[--contextual "語1,語2"] [--ref ref.txt] [--seconds N]

"""

var opts = Options()
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--engine": opts.engine = args.next() ?? ""
        case "--file": opts.file = args.next()
        case "--live": opts.live = true
        case "--locale": opts.locale = args.next() ?? opts.locale
        case "--contextual":
            opts.contextual = (args.next() ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "--ref": opts.ref = args.next()
        case "--seconds": opts.seconds = Double(args.next() ?? "")
        case "-h", "--help": print(usage, terminator: ""); exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(a)\n\(usage)".data(using: .utf8)!)
            exit(2)
        }
    }
}
guard ["dictation", "sf", "transcriber"].contains(opts.engine),
      opts.engine == "transcriber" || (opts.file != nil) != opts.live
else {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(2)
}

// sf は音声認識の TCC 許可が要る。TCC は「責任プロセス」（起動元の Orca.app やターミナル）の Info.plist で
// NSSpeechRecognitionUsageDescription を探し、無いと SIGABRT で落とす（実測。埋め込んだ __info_plist は見られない）。
// そこで自分自身を責任プロセスとして起動し直す（responsibility_spawnattrs_setdisclaim。非公開 API、スパイク限定）。
// dictation は音声認識の許可を求めずに動いた（実測）ので、起動し直さない（マイク許可も起動元のものを使える）。
if opts.engine == "sf", ProcessInfo.processInfo.environment["APPLESPEECHPROBE_DISCLAIMED"] == nil {
    exit(Respawn.disclaimed())
}

let exitCode = await Probe.run(opts)
exit(exitCode)

enum Respawn {
    @_silgen_name("responsibility_spawnattrs_setdisclaim")
    static func setDisclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

    static func disclaimed() -> Int32 {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        guard setDisclaim(&attr, 1) == 0 else { print("ERROR: setdisclaim 失敗"); return 1 }
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.merging(["APPLESPEECHPROBE_DISCLAIMED": "1"]) { $1 }
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0)=\($1)") } + [nil]
        signal(SIGINT, SIG_IGN)  // Ctrl-C は子が受けて後始末する。親は待つだけ
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, &attr, argv, envp)
        guard rc == 0 else { print("ERROR: posix_spawn \(rc)"); return 1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let sig = status & 0x7f
        return sig == 0 ? (status >> 8) & 0xff : 128 + sig
    }
}

// MARK: - 本体

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// 一度だけ実行するための小さな箱（コールバックの多重呼び出し対策）。
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

func fmt(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }

enum Probe {
    static func run(_ o: Options) async -> Int32 {
        do {
            switch o.engine {
            case "transcriber":
                await transcriberInfo(o)
            case "dictation", "sf":
                if o.live { try await live(o) } else { try await file(o) }
            default:
                return 2
            }
            return 0
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }

    // MARK: transcriber（情報表示のみ）

    static func transcriberInfo(_ o: Options) async {
        let want = Locale(identifier: o.locale)
        print("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        let st = await SpeechTranscriber.supportedLocales
        print("SpeechTranscriber.supportedLocales: \(st.count) 件 \(st.map(\.identifier).sorted())")
        let stEq = await SpeechTranscriber.supportedLocale(equivalentTo: want)
        print("SpeechTranscriber.supportedLocale(equivalentTo: \(o.locale)): \(stEq?.identifier ?? "nil")")
        let stInst = await SpeechTranscriber.installedLocales
        print("SpeechTranscriber.installedLocales: \(stInst.count) 件 \(stInst.map(\.identifier).sorted())")
        let dt = await DictationTranscriber.supportedLocales
        print("DictationTranscriber.supportedLocales: \(dt.count) 件")
        let dtEq = await DictationTranscriber.supportedLocale(equivalentTo: want)
        print("DictationTranscriber.supportedLocale(equivalentTo: \(o.locale)): \(dtEq?.identifier ?? "nil")")
        let dtInst = await DictationTranscriber.installedLocales
        print("DictationTranscriber.installedLocales: \(dtInst.count) 件 \(dtInst.map(\.identifier).sorted())")
        print("contextual strings: AnalysisContext.contextualStrings[.general] を SpeechAnalyzer.setContext(_:) で渡す（モジュール共通）")
    }

    // MARK: 共通

    static func dictationLocale(_ id: String) async throws -> Locale {
        guard let l = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            throw ProbeError("DictationTranscriber が \(id) に対応していない")
        }
        return l
    }

    static func describe(_ p: DictationTranscriber.Preset) -> String {
        "transcriptionOptions=\(p.transcriptionOptions) reportingOptions=\(p.reportingOptions) "
            + "attributeOptions=\(p.attributeOptions) contentHints=\(p.contentHints.count) 件"
    }

    static func ensureAssets(_ modules: [any SpeechModule]) async throws {
        let before = await AssetInventory.status(forModules: modules)
        print("AssetInventory.status: \(before)")
        let t0 = Date()
        if let req = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            print("資産の取得を開始（AssetInstallationRequest）")
            try await req.downloadAndInstall()
            print("資産の取得: \(fmt(Date().timeIntervalSince(t0))) 秒（progress \(req.progress.completedUnitCount)/\(req.progress.totalUnitCount)）")
        } else {
            print("資産の取得: 不要（assetInstallationRequest が nil、\(fmt(Date().timeIntervalSince(t0))) 秒）")
        }
        let after = await AssetInventory.status(forModules: modules)
        print("AssetInventory.status（取得後）: \(after)")
    }

    static func context(_ words: [String]) -> AnalysisContext {
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = words
        return ctx
    }

    static func requireSpeechAuthorization() async throws {
        var st = SFSpeechRecognizer.authorizationStatus()
        print("SFSpeechRecognizer.authorizationStatus: \(st.rawValue)（0=未決定 1=拒否 2=制限 3=許可）")
        if st == .notDetermined {
            print("音声認識の許可を要求する（ダイアログが出たら利用者の操作待ち）")
            st = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            print("SFSpeechRecognizer.authorizationStatus（要求後）: \(st.rawValue)")
        }
        guard st == .authorized else { throw ProbeError("音声認識が許可されていない（status \(st.rawValue)）") }
    }

    static func requireMicAuthorization() async throws {
        let st = AVCaptureDevice.authorizationStatus(for: .audio)
        print("マイク許可: \(st.rawValue)（0=未決定 1=制限 2=拒否 3=許可）")
        if st == .notDetermined {
            print("マイクの許可を要求する（ダイアログが出たら利用者の操作待ち）")
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            print("マイク許可（要求後）: \(ok)")
            guard ok else { throw ProbeError("マイクが許可されなかった") }
        } else if st != .authorized {
            throw ProbeError("マイクが許可されていない（status \(st.rawValue)）")
        }
    }

    // MARK: --file

    static func file(_ o: Options) async throws {
        var url = URL(fileURLWithPath: o.file!)
        if let s = o.seconds { url = try trim(url, seconds: s) }
        let audio = try AVAudioFile(forReading: url)
        let audioSec = Double(audio.length) / audio.processingFormat.sampleRate
        print("engine: \(o.engine)  locale: \(o.locale)  file: \(url.path)  音声秒: \(fmt(audioSec, 1))  "
            + "contextual: \(o.contextual)")

        let text: String
        let elapsed: Double
        if o.engine == "dictation" {
            (text, elapsed) = try await dictationFile(url, o)
        } else {
            (text, elapsed) = try await sfFile(url, o)
        }

        let hypURL = FileManager.default.temporaryDirectory.appendingPathComponent("AppleSpeechProbe-\(o.engine)-hyp.txt")
        try (text + "\n").write(to: hypURL, atomically: true, encoding: .utf8)
        print("経過秒: \(fmt(elapsed))")
        print("RTF: \(fmt(elapsed / audioSec, 3))")
        if let ref = o.ref {
            print("CER: \(cer(hyp: hypURL.path, ref: ref, extra: []))")
            print("CER（--no-punct）: \(cer(hyp: hypURL.path, ref: ref, extra: ["--no-punct"]))")
        }
        print("文字数: \(text.count)  全文: \(hypURL.path)")
        print("先頭 200 文字: \(String(text.prefix(200)))")
    }

    /// 先頭 N 秒を一時 WAV に切り出す。
    static func trim(_ src: URL, seconds: Double) throws -> URL {
        let inFile = try AVAudioFile(forReading: src)
        let frames = AVAudioFrameCount(min(Double(inFile.length), seconds * inFile.processingFormat.sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: frames) else {
            throw ProbeError("バッファを作れない")
        }
        try inFile.read(into: buf, frameCount: frames)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("AppleSpeechProbe-trim-\(Int(seconds))s.wav")
        try? FileManager.default.removeItem(at: dst)
        do {
            let out = try AVAudioFile(forWriting: dst, settings: inFile.fileFormat.settings,
                                      commonFormat: inFile.processingFormat.commonFormat,
                                      interleaved: inFile.processingFormat.isInterleaved)
            try out.write(from: buf)
        } // ここで out が解放され、WAV のヘッダが確定する
        return dst
    }

    static func cer(hyp: String, ref: String, extra: [String]) -> String {
        let fm = FileManager.default
        guard let script = ["scripts/cer.py", "../scripts/cer.py"].first(where: { fm.fileExists(atPath: $0) }) else {
            return "scripts/cer.py が見つからない（リポジトリ直下か Spikes/ から実行する）"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", script] + extra + [hyp, ref]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "python3 を起動できない: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? s : "cer.py exit \(p.terminationStatus): \(s)"
    }

    static func dictationFile(_ url: URL, _ o: Options) async throws -> (String, Double) {
        let s0 = Date()
        let locale = try await dictationLocale(o.locale)
        let preset = DictationTranscriber.Preset.longDictation
        print("DictationTranscriber locale=\(locale.identifier) preset=.longDictation（\(describe(preset))）")
        let t = DictationTranscriber(locale: locale, preset: preset)
        try await ensureAssets([t])
        let analyzer = SpeechAnalyzer(modules: [t])
        if !o.contextual.isEmpty { try await analyzer.setContext(context(o.contextual)) }
        print("準備秒（ロケール・資産確認・初期化）: \(fmt(Date().timeIntervalSince(s0)))")

        let collector = Task { () async throws -> [String] in
            var parts: [String] = []
            var n = 0
            for try await r in t.results {
                n += 1
                if r.isFinal { parts.append(String(r.text.characters)) }
            }
            print("結果の件数: \(n)（確定 \(parts.count)）")
            return parts
        }
        let audio = try AVAudioFile(forReading: url)
        let t0 = Date()
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let parts = try await collector.value
        return (parts.joined(), Date().timeIntervalSince(t0))
    }

    static func sfFile(_ url: URL, _ o: Options) async throws -> (String, Double) {
        try await requireSpeechAuthorization()
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: o.locale)) else {
            throw ProbeError("SFSpeechRecognizer が \(o.locale) を作れない")
        }
        print("SFSpeechRecognizer isAvailable=\(rec.isAvailable) supportsOnDeviceRecognition=\(rec.supportsOnDeviceRecognition)")
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        req.contextualStrings = o.contextual
        let box = SFCollector()
        let t0 = Date()
        let text: String = try await withCheckedThrowingContinuation { cont in
            box.task = rec.recognitionTask(with: req) { result, error in
                box.handle(result: result, error: error, t0: t0, cont: cont)
            }
        }
        let elapsed = Date().timeIntervalSince(t0)
        // 確定のあとに追加の結果が来ないか（1 分ごとに区切られる等）を 2 秒だけ見る
        try? await Task.sleep(for: .seconds(2))
        print("コールバック回数: \(box.callbacks)（確定後の追加: \(box.callbacksAfterFinal)）")
        withExtendedLifetime(rec) {}
        return (text, elapsed)
    }

    // MARK: --live

    static func live(_ o: Options) async throws {
        try await requireMicAuthorization()
        if o.engine == "dictation" { try await dictationLive(o) } else { try await sfLive(o) }
    }

    static func dictationLive(_ o: Options) async throws {
        let locale = try await dictationLocale(o.locale)
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        print("DictationTranscriber locale=\(locale.identifier) preset=.progressiveLongDictation（\(describe(preset))） contextual=\(o.contextual)")
        let t = DictationTranscriber(locale: locale, preset: preset)
        try await ensureAssets([t])
        let analyzer = SpeechAnalyzer(modules: [t])
        if !o.contextual.isEmpty { try await analyzer.setContext(context(o.contextual)) }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw ProbeError("bestAvailableAudioFormat が nil")
        }
        print("解析の入力形式: \(format)")
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let mic = try MicCapture(target: format) { buf in cont.yield(AnalyzerInput(buffer: buf)) }
        let t0 = Date()
        let printer = Task {
            for try await r in t.results {
                let wall = Date().timeIntervalSince(t0)
                let audioEnd = r.range.end.seconds
                print("[+\(fmt(wall, 1))] \(r.isFinal ? "確定" : "部分"): \(String(r.text.characters)) (音声 ~\(fmt(audioEnd, 1))s)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        try mic.start()
        print("[+0.0] 録音開始（Ctrl-C で終了\(o.seconds.map { "、\(fmt($0, 0)) 秒で自動終了" } ?? "")）")
        await waitForStop(seconds: o.seconds)
        mic.stop()
        cont.finish()
        print("[+\(fmt(Date().timeIntervalSince(t0), 1))] 録音終了、確定を待つ")
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await printer.value
        print("[+\(fmt(Date().timeIntervalSince(t0), 1))] 終了")
    }

    static func sfLive(_ o: Options) async throws {
        try await requireSpeechAuthorization()
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: o.locale)) else {
            throw ProbeError("SFSpeechRecognizer が \(o.locale) を作れない")
        }
        print("SFSpeechRecognizer isAvailable=\(rec.isAvailable) supportsOnDeviceRecognition=\(rec.supportsOnDeviceRecognition) contextual=\(o.contextual)")
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.contextualStrings = o.contextual
        let mic = try MicCapture(target: nil) { buf in req.append(buf) }
        let t0 = Date()
        let task = rec.recognitionTask(with: req) { result, error in
            let wall = fmt(Date().timeIntervalSince(t0), 1)
            if let result {
                print("[+\(wall)] \(result.isFinal ? "確定" : "部分"): \(result.bestTranscription.formattedString)")
            }
            if let error { print("[+\(wall)] タスク終了（エラー）: \(error)") }
        }
        try mic.start()
        print("[+0.0] 録音開始（Ctrl-C で終了\(o.seconds.map { "、\(fmt($0, 0)) 秒で自動終了" } ?? "")）")
        await waitForStop(seconds: o.seconds)
        mic.stop()
        req.endAudio()
        print("[+\(fmt(Date().timeIntervalSince(t0), 1))] 録音終了、確定を待つ")
        try? await Task.sleep(for: .seconds(5))
        print("[+\(fmt(Date().timeIntervalSince(t0), 1))] 終了（task.state=\(task.state.rawValue)）")
        withExtendedLifetime(rec) {}
    }

    /// SIGINT か seconds 秒の早いほうまで待つ。
    static func waitForStop(seconds: Double?) async {
        let once = Once()
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            src.setEventHandler { if once.fire() { c.resume() } }
            src.resume()
            if let seconds {
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if once.fire() { c.resume() } }
            }
        }
        src.cancel()
    }
}

/// SFSpeechRecognizer のコールバックを受ける箱。コールバックは認識スレッドから来る。
final class SFCollector: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var done = false
    private(set) var callbacks = 0
    private(set) var callbacksAfterFinal = 0
    private var chunks: [String] = []

    func handle(result: SFSpeechRecognitionResult?, error: Error?, t0: Date,
                cont: CheckedContinuation<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        let wall = fmt(Date().timeIntervalSince(t0), 1)
        if done {
            callbacksAfterFinal += 1
            print("[+\(wall)] 確定後のコールバック: final=\(result?.isFinal ?? false) error=\(error.map { "\($0)" } ?? "なし") "
                + "文字数=\(result?.bestTranscription.formattedString.count ?? 0)")
            return
        }
        if let result {
            // 実測: on-device では shouldReportPartialResults = false でも、約 1 分ごとに非確定の結果が届き、
            // 確定（isFinal）の bestTranscription は最後の区間しか持たない。区間ごとに記録して連結する。
            let segs = result.bestTranscription.segments
            let first = segs.first?.timestamp ?? 0
            let lastEnd = segs.last.map { $0.timestamp + $0.duration } ?? 0
            let text = result.bestTranscription.formattedString
            print("[+\(wall)] \(result.isFinal ? "確定" : "区間"): セグメント \(segs.count) 個、"
                + "\(fmt(first, 1))〜\(fmt(lastEnd, 1)) 秒、\(text.count) 文字")
            chunks.append(text)
            if result.isFinal {
                done = true
                print("区間数: \(chunks.count)（確定の bestTranscription 単体は \(text.count) 文字）")
                cont.resume(returning: chunks.joined())
            }
        } else if let error {
            done = true
            cont.resume(throwing: ProbeError("SFSpeechRecognizer: \(error)"))
        }
    }
}

/// 既定の入力デバイスから音を取る。target を渡すとその形式に変換してから sink に渡す。
final class MicCapture: @unchecked Sendable {
    let engine = AVAudioEngine()
    let inFormat: AVAudioFormat
    let converter: AVAudioConverter?
    let target: AVAudioFormat?
    let sink: @Sendable (AVAudioPCMBuffer) -> Void

    init(target: AVAudioFormat?, sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        inFormat = engine.inputNode.outputFormat(forBus: 0)
        print("入力形式: \(inFormat)")
        guard inFormat.sampleRate > 0 else { throw ProbeError("入力デバイスが無い（sampleRate 0）") }
        self.target = target
        self.sink = sink
        if let target, target != inFormat {
            guard let c = AVAudioConverter(from: inFormat, to: target) else {
                throw ProbeError("AVAudioConverter を作れない: \(inFormat) → \(target)")
            }
            converter = c
        } else {
            converter = nil
        }
    }

    func start() throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [self] buf, _ in
            self.process(buf)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let converter, let target else { sink(buf); return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / inFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        nonisolated(unsafe) var fed = false  // convert の入力ブロックは同期で呼ばれる
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return buf
        }
        if status == .error { print("変換エラー: \(err.map { "\($0)" } ?? "?")"); return }
        if out.frameLength > 0 { sink(out) }
    }
}
