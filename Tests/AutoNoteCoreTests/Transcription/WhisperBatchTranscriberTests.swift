import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Synchronization
import Testing

@Suite struct WhisperBatchTranscriberTests {
    private func transcribe(
        _ core: FakeWhisperCore, seconds: Double = 4, language: Language = .ja, hints: [String] = [],
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> [Utterance] {
        try await WhisperBatchTranscriber(core: core, gate: BatchGate())
            .transcribe(file: try wavFile(tone(seconds)), language: language, hints: hints, progress: progress)
    }

    @Test func segmentsBecomeFinalUtterances() async throws {
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "こんにちは"), .init(start: 2, end: 4, text: "よろしく")])
        let u = try await transcribe(core)
        #expect(u.map(\.start.seconds) == [0, 2])
        #expect(u.map { $0.end?.seconds } == [2, 4])
        #expect(u.map(\.text) == ["こんにちは", "よろしく"])
        #expect(u.allSatisfy { $0.isFinal && $0.speaker == .unknown })
    }

    @Test func progressIsMonotonicAndEndsAtOne() async throws {
        let core = FakeWhisperCore(segments: [
            .init(start: 0, end: 2, text: "一"), .init(start: 2, end: 4, text: "二"), .init(start: 4, end: 6, text: "三"),
        ])
        let box = ProgressBox()
        _ = try await transcribe(core, seconds: 6, progress: { box.append($0) })
        let values = box.values
        #expect(values.count >= 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values.last == 1.0)
    }

    @Test func cancellationStopsAndThrows() async throws {
        let core = FakeWhisperCore(
            segments: (0..<20).map { .init(start: Double($0), end: Double($0 + 1), text: "\($0)") }, delay: .milliseconds(100))
        let file = try wavFile(tone(20))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: BatchGate())
                .transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await waitUntil { core.emittedCount >= 1 }
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        #expect(core.runCount == 1)
        #expect(core.emittedCount < 20)
    }

    @Test func pauseAbortsAndResumesFromLastSegmentEnd() async throws {
        // 1 つ目が出た後に pause → 2 つ目（2–4）の境界で .aborted。resume 後の 2 本目は offset 4 から 3 つ目だけを出す
        let gate = BatchGate()
        let core = FakeWhisperCore(
            segments: [.init(start: 0, end: 2, text: "一"), .init(start: 2, end: 4, text: "二"), .init(start: 4, end: 6, text: "三")],
            delay: .milliseconds(200))
        let file = try wavFile(tone(6))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate).transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await waitUntil { core.emittedCount >= 1 }
        await gate.pause()
        #expect(gate.isPaused)
        try await waitUntil { core.emittedCount >= 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(core.runCount == 1)   // 一時停止中は 2 本目を始めない
        await gate.resume()
        #expect(!gate.isPaused)
        let u = try await t.value
        #expect(core.requests.map(\.offsetSeconds) == [0, 4])
        #expect(u.map(\.text) == ["一", "二", "三"])
    }

    @Test func cancellationWhilePausedThrowsPromptly() async throws {
        let gate = BatchGate()
        await gate.pause()
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "一")])
        let file = try wavFile(tone(2))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate).transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ContinuousClock.now
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(gate.isPaused)
        #expect(core.runCount == 0)
    }

    @Test func pausedGateHoldsTheFirstRun() async throws {
        let gate = BatchGate()
        await gate.pause()
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "一")])
        let file = try wavFile(tone(2))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate).transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(core.runCount == 0)
        await gate.resume()
        #expect(try await t.value.map(\.text) == ["一"])
    }

    @Test func repetitionFilterIsApplied() async throws {
        let core = FakeWhisperCore(segments: [
            .init(start: 0, end: 2, text: "了解です"), .init(start: 2, end: 4, text: "了解です。"),
            .init(start: 4, end: 6, text: "ご視聴ありがとうございました"),
        ])
        #expect(try await transcribe(core, seconds: 6).map(\.text) == ["了解です"])
    }

    @Test func hintsBecomePrompt() async throws {
        let core = FakeWhisperCore(segments: [])
        _ = try await transcribe(core, hints: ["所沢", "Kubernetes"])
        #expect(core.requests.first?.prompt == "所沢、Kubernetes")
    }

    @Test func noHintsNoPrompt() async throws {
        let core = FakeWhisperCore(segments: [])
        _ = try await transcribe(core)
        #expect(core.requests.count == 1)
        #expect(core.requests[0].prompt == nil)
    }

    @Test func languageIsForwarded() async throws {
        let core = FakeWhisperCore(segments: [])
        _ = try await transcribe(core, language: .en)
        #expect(core.requests[0].language == .en)
        #expect(core.requests[0].mode == .batch)
        #expect(core.requests[0].offsetSeconds == 0)
        #expect(core.requests[0].samples.count == 4 * 16_000)
    }

    @Test func silentSegmentIsDropped() async throws {
        // 0–2 s silence, 2–4 s tone: the segment over silence is a hallucination, the one over the tone is speech
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "本日の動画でお会いしましょう"),
                                              .init(start: 2, end: 4, text: "よろしく")])
        let u = try await WhisperBatchTranscriber(core: core, gate: BatchGate())
            .transcribe(file: try wavFile(silence(2) + tone(2)), language: .ja, hints: [], progress: { _ in })
        #expect(u.map(\.text) == ["よろしく"])
    }

    @Test func segmentWithTooLittleSpeechIsDropped() async throws {
        // 1.9–2.1 s overlaps only 0.1 s of tone (< 0.3 s)
        let core = FakeWhisperCore(segments: [.init(start: 1.9, end: 2.1, text: "ん"), .init(start: 2.1, end: 4, text: "はい")])
        let u = try await WhisperBatchTranscriber(core: core, gate: BatchGate())
            .transcribe(file: try wavFile(silence(2) + tone(2)), language: .ja, hints: [], progress: { _ in })
        #expect(u.map(\.text) == ["はい"])
    }
}

// MARK: - Windows (nominal 20 s so a test file of tens of seconds spans several windows)

private let small = BatchWindowPlanner.Config(nominal: 20, lookback: 6, overlap: 5, tailMerge: 4)
private func seg(_ a: Double, _ b: Double, _ t: String) -> WhisperSegment { .init(start: a, end: b, text: t) }
private func run(_ core: FakeWhisperCore, _ pcm: [Int16], language: Language = .ja, hints: [String] = [],
                 gate: BatchGate = BatchGate(),
                 log: @escaping @Sendable (String) -> Void = { _ in },
                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Utterance] {
    try await WhisperBatchTranscriber(core: core, gate: gate, windows: small, log: log)
        .transcribe(file: try wavFile(pcm), language: language, hints: hints, progress: progress)
}

/// Log lines (and, for the progress test, progress values) in the order they arrived.
private final class ProgressLog: @unchecked Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ value: String) { storage.withLock { $0.append(value) } }
    var values: [String] { storage.withLock { $0 } }
}

extension WhisperBatchTranscriberTests {
    @Test func shortFileIsOneWindowWithAllSamples() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 23, "一")]])
        #expect(try await run(core, tone(23)).map(\.text) == ["一"])
        #expect(core.requests.map(\.samples.count) == [23 * 16_000])
        #expect(core.requests.map(\.offsetSeconds) == [0])
    }

    @Test func silenceCutDoesNotOverlap() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "一"), seg(8, 16, "二")], [seg(0, 10, "三"), seg(10, 23, "四")]])
        let u = try await run(core, tone(16) + silence(2) + tone(22))
        #expect(core.requests.map(\.samples.count) == [17 * 16_000, 23 * 16_000])   // 合計が全長 = 重なりなし
        #expect(u.map(\.start.seconds) == [0, 8, 17, 27])
        #expect(u.map(\.text) == ["一", "二", "三", "四"])
    }

    @Test func silenceCutKeepsASegmentRunningPastTheCut() async throws {
        // whisper は終了時刻を音声長で切り詰めない: 窓 1（0–17 秒）の「尾」は 15.5–19.5 秒、中点 17.5 秒は切れ目の後ろ
        let core = FakeWhisperCore(windows: [[seg(0, 8, "一"), seg(15.5, 19.5, "尾")], [seg(0, 10, "三")]])
        let u = try await run(core, tone(16) + silence(2) + tone(22))
        #expect(u.map(\.text) == ["一", "尾", "三"])
    }

    @Test func hardCutOverlapsAndKeepsEachSegmentOnce() async throws {
        // 窓 2 は 15 秒から読む
        let core = FakeWhisperCore(windows: [
            [seg(0, 9, "一"), seg(9, 18, "二"), seg(18, 21.5, "三"), seg(21.5, 25, "四（前の窓）")],
            [seg(0, 3, "二（後の窓）"), seg(3, 6.5, "三（後の窓）"), seg(6.5, 12, "四"), seg(12, 25, "五")]])
        let u = try await run(core, tone(40))
        #expect(core.requests.map(\.samples.count) == [25 * 16_000, 25 * 16_000])
        #expect(u.map(\.text) == ["一", "二", "三", "四", "五"])
        #expect(u.map(\.start.seconds) == [0, 9, 18, 21.5, 27])
    }

    @Test func timesAreShiftedAndMonotonic() async throws {
        // 45 秒は 0・15・35 秒から読む 3 窓
        let core = FakeWhisperCore(windows: [[seg(1, 3, "a")], [seg(6, 8, "b")], [seg(6, 8, "c")]])
        let u = try await run(core, tone(45))
        #expect(u.map(\.start.seconds) == [1, 21, 41])
        #expect(u.map { $0.end?.seconds } == [3, 23, 43])
        #expect(zip(u, u.dropFirst()).allSatisfy { $0.start.seconds < $1.start.seconds })
    }

    @Test func requestsCarryOnlyTheWindowSamples() async throws {
        let core = FakeWhisperCore(windows: [[seg(1, 3, "a")], [seg(6, 8, "b")], [seg(6, 8, "c")]])
        _ = try await run(core, tone(45), language: .en, hints: ["所沢"])
        #expect(core.requests.map(\.samples.count) == [25 * 16_000, 30 * 16_000, 10 * 16_000])
        // 前の窓の末尾をプロンプトに足さない（設計書のアンチゴール）
        #expect(core.requests.allSatisfy { $0.language == .en && $0.prompt == "所沢" && $0.mode == .batch })
    }

    @Test func silenceFilterUsesTheWindowPCM() async throws {
        // 17 秒で切れる。窓 2（17–40 秒）の 11–15 秒 = ファイルの 28–32 秒は無音、15–23 秒 = 32–40 秒は tone
        let core = FakeWhisperCore(windows: [[seg(0, 16, "一")], [seg(11, 15, "幻"), seg(15, 23, "はい")]])
        let u = try await run(core, tone(16) + silence(2) + tone(10) + silence(4) + tone(8))
        #expect(u.map(\.text) == ["一", "はい"])
    }

    @Test func silentWindowIsStillDecodedAndYieldsNothing() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 16, "一")], [seg(2, 10, "幻")]])
        let u = try await run(core, tone(16) + silence(24))   // 18 秒で切れ、窓 2 はまるごと無音
        #expect(core.runCount == 2)
        #expect(u.map(\.text) == ["一"])
    }

    @Test func logsOneLinePerWindow() async throws {
        let lines = ProgressLog()
        _ = try await run(FakeWhisperCore(windows: []), tone(40), log: { lines.append($0) })
        #expect(lines.values == ["文字起こし 窓 1/2（0 分 / 1 分）", "文字起こし 窓 2/2（1 分 / 1 分）"])
    }

    @Test func progressReachesHalfAfterTheFirstOfTwoEqualWindows() async throws {
        let events = ProgressLog()
        let box = ProgressBox()
        let core = FakeWhisperCore(windows: [[seg(0, 10, "一"), seg(10, 20, "二")], [seg(5, 15, "三"), seg(15, 25, "四")]])
        _ = try await run(core, tone(40), log: { _ in events.append("log") },
                          progress: { box.append($0); events.append("\($0)") })
        let values = box.values
        // 窓 1 のログの直前に出た進捗が 0.5
        let firstLog = try #require(events.values.firstIndex(of: "log"))
        #expect(firstLog > 0)
        #expect(events.values[firstLog - 1] == "\(0.5)")
        #expect(values.contains { $0 > 0 && $0 < 0.5 })
        #expect(values.contains { $0 > 0.5 && $0 < 1 })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == 1.0)
    }

    @Test func cancellationDuringFirstWindowNeverStartsTheSecond() async throws {
        let core = FakeWhisperCore(windows: [(0..<20).map { seg(Double($0), Double($0 + 1), "\($0)") }], delay: .milliseconds(100))
        let file = try wavFile(tone(40))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: BatchGate(), windows: small, log: { _ in })
                .transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await waitUntil { core.emittedCount >= 1 }
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        #expect(core.runCount == 1)
    }

    @Test func pausedGateHoldsTheNextWindow() async throws {
        // 窓 1 の唯一のセグメントが出る前（delay 中）に pause → そのセグメントの境界で中断し、窓 1 の再開（offset 9）も窓 2 も始めない
        let gate = BatchGate()
        let core = FakeWhisperCore(windows: [[seg(0, 9, "一")], [seg(6.5, 12, "四")]], delay: .milliseconds(200))
        let file = try wavFile(tone(40))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate, windows: small, log: { _ in })
                .transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await waitUntil { core.runCount >= 1 }
        await gate.pause()
        try await waitUntil { core.emittedCount >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(core.runCount == 1)
        await gate.resume()
        #expect(try await t.value.map(\.text) == ["一", "四"])
        #expect(core.requests.map(\.offsetSeconds) == [0, 9, 0])   // 窓 1 の再開は台本に残りが無く空で終わる
    }

    @Test func pauseInsideAWindowResumesFromItsLastSegment() async throws {
        let gate = BatchGate()
        let core = FakeWhisperCore(
            windows: [[seg(0, 9, "一")], [seg(6.5, 12, "四"), seg(12, 18, "五"), seg(18, 25, "六")]], delay: .milliseconds(200))
        let file = try wavFile(tone(40))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate, windows: small, log: { _ in })
                .transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await waitUntil { core.emittedCount >= 2 }   // 一・四
        await gate.pause()
        try await waitUntil { core.emittedCount >= 3 }   // 五の境界で中断
        try await Task.sleep(for: .milliseconds(300))
        #expect(core.runCount == 2)
        await gate.resume()
        #expect(try await t.value.map(\.text) == ["一", "四", "五", "六"])
        #expect(core.requests.map(\.offsetSeconds) == [0, 0, 18])
    }

    @Test func non16kMonoWAVIsInvalidAudio() async throws {
        let body = tone(2)
        let url = try TemporaryDirectory.make().appending(path: "audio.wav")
        var data = WAVFile.header(sampleRate: 44_100, channels: 1, bitsPerSample: 16, dataBytes: body.count * 2)
        body.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
        let core = FakeWhisperCore(windows: [[seg(0, 1, "一")]])
        await #expect {
            _ = try await WhisperBatchTranscriber(core: core, gate: BatchGate(), windows: small, log: { _ in })
                .transcribe(file: url, language: .ja, hints: [], progress: { _ in })
        } throws: { error in
            guard case .invalidAudio? = error as? TranscriptionError else { return false }
            return true
        }
        #expect(core.runCount == 0)
    }

    @Test func emptyFileMakesOneEmptyRun() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 1, "幻")]])
        let u = try await run(core, [])
        #expect(core.runCount == 1)
        #expect(core.requests.map(\.samples.count) == [0])
        #expect(u.isEmpty)
    }

    /// 文字種の制限はライブだけ。確定版（beam 5・temperature fallback・10 分窓の中で文脈を引き継ぐ）は、禁止したトークンの
    /// わずかな確率の付け替えで経路が変わり、英語の会議を ja 固定で回すと繰り返しに入って後半が消えた（2026-11-19 の評価）。
    @Test(arguments: [Language.ja, .en, .auto])
    func batchDecodingIsNotScriptRestricted(language: Language) async throws {
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "こんにちは")])
        _ = try await transcribe(core, language: language)
        #expect(!core.requests.isEmpty)
        #expect(core.requests.allSatisfy { $0.scripts == .unrestricted })
    }
}

// MARK: - Auto (Japanese or English per run of a window)

extension WhisperBatchTranscriberTests {
    /// 単一言語なら窓全体が 1 区間になり、その言語を固定した 1 回の呼び出しになる（固定の言語と同じ）。
    @Test func autoInOneLanguageDecodesTheWholeWindowOnce() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "一"), seg(9, 17, "二")]])
        core.guess = { _ in LanguageGuess(ja: 0.1, en: 0.85) }
        let pcm = tone(8) + silence(1) + tone(8)
        let u = try await run(core, pcm, language: .auto)
        #expect(core.detections.count == 2)
        #expect(core.requests.map(\.language) == [.en])
        #expect(core.requests.map(\.samples.count) == [pcm.count])
        #expect(core.requests.allSatisfy { $0.offsetSeconds == 0 && $0.scripts == .unrestricted })
        #expect(u.map(\.text) == ["一", "二"])
    }

    /// 言語が変わる所（無音の中）で区間を分け、それぞれの言語で起こす。時刻は区間の始まりの分ずらす。
    /// （台本の windows は offset 0 の呼び出しごとに進むので、ここでは区間ごとの台本になる）
    @Test func autoDecodesEachLanguageRunWithItsLanguage() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "Hello there")], [seg(0.5, 8.5, "こんにちは")]])
        core.guess = { samples in samples.count < 9 * 16_000 ? LanguageGuess(ja: 0.01, en: 0.97) : LanguageGuess(ja: 0.9, en: 0.05) }
        let lines = ProgressLog()
        let u = try await run(core, tone(8) + silence(1) + tone(9), language: .auto, log: { lines.append($0) })
        #expect(core.requests.map(\.language) == [.en, .ja])
        #expect(core.requests.map(\.samples.count) == [Int(8.25 * 16_000), Int(9.75 * 16_000)])
        #expect(u.map(\.text) == ["Hello there", "こんにちは"])
        #expect(u.map(\.start.seconds) == [0, 8.75])
        #expect(lines.values.first == "言語 窓 1/1: en 0–8 秒、ja 8–18 秒")
    }

    @Test func fixedLanguageNeverAsksForDetection() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "一")]])
        _ = try await run(core, tone(8) + silence(1) + tone(8), language: .ja)
        #expect(core.detections.isEmpty)
    }

    @Test func autoOnAnEmptyFileStillMakesOneEmptyRun() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 1, "幻")]])
        let u = try await run(core, [], language: .auto)
        #expect(core.requests.map(\.samples.count) == [0])
        #expect(core.requests.map(\.language) == [.ja])
        #expect(u.isEmpty)
    }
}

// MARK: - Auto: review findings (REVIEW.md R1–R4, M1–M3, L1)

private let enGuess = LanguageGuess(ja: 0.01, en: 0.97)
private let jaGuess = LanguageGuess(ja: 0.9, en: 0.05)

extension WhisperBatchTranscriberTests {
    /// R1 / M1: 判定できる塊が無い窓（発話 2 秒未満）も、発話があれば窓を 1 回判定して、その言語で起こす。
    @Test func aWindowWithOnlyAShortUtteranceIsJudgedOnce() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 1.5, "Thanks")]])
        core.guess = { _ in enGuess }
        let u = try await run(core, tone(1.5) + silence(5), language: .auto)
        #expect(core.detections.count == 1)
        #expect(core.requests.map(\.language) == [.en])
        #expect(u.map(\.text) == ["Thanks"])
    }

    /// M1: 確かな判定が無い窓は、前の窓の最後の言語を引き継ぐ（無音の窓・迷う判定の窓）。
    @Test func aWindowWithNothingDecisiveKeepsTheLanguageOfTheWindowBefore() async throws {
        // 窓 1（0–17 秒）は en、窓 2（17–40 秒）は迷う判定だけ（en の割合 0.55）、窓 3 は無音
        let core = FakeWhisperCore(windows: [[seg(0, 8, "Hello")], [seg(0, 9, "Well")], []])
        // 窓 1 の塊は 8.25 秒・8.75 秒、窓 2 の塊は 17 秒（窓全体）
        core.guess = { samples in samples.count < 9 * 16_000 ? enGuess : LanguageGuess(ja: 0.4, en: 0.5) }
        let u = try await run(core, tone(8) + silence(1) + tone(7) + silence(2) + tone(9) + silence(25), language: .auto)
        #expect(core.detections.count == 3)   // 窓 3 は無音なので判定しない
        #expect(core.requests.map(\.language) == [.en, .en, .en])
        #expect(u.map(\.text) == ["Hello", "Well"])
    }

    @Test func theFirstWindowWithNothingToGoOnIsJapanese() async throws {
        let core = FakeWhisperCore(windows: [[]])
        _ = try await run(core, silence(10), language: .auto)
        #expect(core.detections.isEmpty)
        #expect(core.requests.map(\.language) == [.ja])
    }

    /// R2 / L1: 判定の失敗はログに残して「判定しなかった」扱い。起こしは続ける。
    @Test func aFailedJudgementIsLoggedAndTreatedAsNone() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "一"), seg(9, 17, "二")]])
        core.detectionError = TranscriptionError.whisperFailed(-6)
        let lines = ProgressLog()
        let u = try await run(core, tone(8) + silence(1) + tone(9), language: .auto, log: { lines.append($0) })
        #expect(core.requests.map(\.language) == [.ja])
        #expect(u.map(\.text) == ["一", "二"])
        #expect(lines.values.contains { $0.hasPrefix("言語の判定に失敗（直前の言語を使う）") })
    }

    @Test func aCancelledJudgementStillThrows() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "一")]])
        core.detectionError = CancellationError()
        await #expect(throws: CancellationError.self) {
            _ = try await run(core, tone(8) + silence(1) + tone(9), language: .auto)
        }
        #expect(core.runCount == 0)
    }

    /// R3 / M2: 区間の末尾の無音に出た幻（終わりが次の区間にはみ出す）は、次の区間の発話で無音判定を通らない。
    @Test func aHallucinationAtTheEndOfARunIsDropped() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "Hello"), seg(8.05, 10, "幻")], [seg(0.5, 8.5, "こんにちは")]])
        core.guess = { s in s.count < 9 * 16_000 ? enGuess : jaGuess }
        let u = try await run(core, tone(8) + silence(1) + tone(9), language: .auto)
        #expect(u.map(\.text) == ["Hello", "こんにちは"])
    }

    /// 窓の末尾をはみ出すセグメントは、固定の言語でも自動でも残る（始まりが窓の中なので）。
    @Test func aSegmentStartingInsideTheWindowAndRunningPastItIsKept() async throws {
        // 窓 1（0–17 秒）の「尾」は 15.5–19.5 秒
        for language in [Language.ja, .auto] {
            let core = FakeWhisperCore(windows: [[seg(0, 8, "一"), seg(15.5, 19.5, "尾")], [seg(0, 10, "三")]])
            let u = try await run(core, tone(16) + silence(2) + tone(22), language: language)
            #expect(u.map(\.text) == ["一", "尾", "三"], "\(language)")
        }
    }

    /// M2 は自動だけ: 区間の終わりより後で始まるセグメント（区間の音声の外に出た幻）は自動では落とし、
    /// 同じ位置に音声がある固定の言語（区間 = 窓）では残す。
    @Test func aSegmentStartingPastItsRunIsDroppedOnlyWithAuto() async throws {
        let script = [[seg(0, 8, "一"), seg(9, 12, "後")], [seg(0.5, 8.5, "二")]]
        let fixed = FakeWhisperCore(windows: script)
        #expect(try await run(fixed, tone(8) + silence(1) + tone(9), language: .ja).map(\.text) == ["一", "後"])
        let auto = FakeWhisperCore(windows: script)
        auto.guess = { s in s.count < 9 * 16_000 ? enGuess : jaGuess }   // 区間 1（0–8.75 秒）は en、区間 2 は ja
        #expect(try await run(auto, tone(8) + silence(1) + tone(9), language: .auto).map(\.text) == ["一", "二"])
    }

    /// R4: 2 つ目の区間の途中で一時停止 → 再開しても、時刻は元の時間軸。
    @Test func pauseInsideTheSecondRunKeepsTimes() async throws {
        let gate = BatchGate()
        let core = FakeWhisperCore(windows: [[seg(0, 8, "Hello")], [seg(0.5, 4, "一"), seg(4, 7, "二"), seg(7, 9.5, "三")]],
                                   delay: .milliseconds(200))
        core.guess = { s in s.count < 9 * 16_000 ? enGuess : jaGuess }
        let file = try wavFile(tone(8) + silence(1) + tone(9))
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate, windows: small, log: { _ in })
                .transcribe(file: file, language: .auto, hints: [], progress: { _ in })
        }
        try await waitUntil { core.emittedCount >= 2 }
        await gate.pause()
        try await waitUntil { core.emittedCount >= 3 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(core.runCount == 2)
        await gate.resume()
        let u = try await t.value
        #expect(core.requests.map(\.offsetSeconds) == [0, 0, 7])
        #expect(core.requests.map(\.language) == [.en, .ja, .ja])
        #expect(u.map(\.text) == ["Hello", "一", "二", "三"])
        #expect(u.map(\.start.seconds) == [0, 8.75, 12.25, 15.25])
    }

    /// M3: Intel は窓ごとに 1 回（whisper の中で ja/en を判定する第 1 段と同じ）。塊ごとの判定はしない。
    @Test func splittingFollowsTheMachine() {
        #expect(AutoLanguageSplitting.for(.appleSilicon) == .perBlock)
        #expect(AutoLanguageSplitting.for(.intel) == .perWindow)
    }

    @Test func perWindowSplittingJudgesOncePerWindowAndPassesTheLanguage() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "一")], [seg(0, 9, "二")]])
        let u = try await WhisperBatchTranscriber(core: core, gate: BatchGate(), windows: small, splitting: .perWindow, log: { _ in })
            .transcribe(file: try wavFile(tone(8) + silence(1) + tone(7) + silence(2) + tone(22)), language: .auto,
                        hints: [], progress: { _ in })
        #expect(core.detections.count == 2)
        #expect(core.requests.map(\.language) == [.ja, .ja])
        #expect(u.map(\.text) == ["一", "二"])
    }

    /// 正しさ F6: 窓ごと（Intel）でも、窓の先頭の無音ではなく発話の始まりから判定する。無音の窓は直前の窓の言語。
    @Test func perWindowSplittingJudgesFromWhereSpeechStarts() async throws {
        let core = FakeWhisperCore(windows: [[seg(10, 16, "Hello")], []])
        core.guess = { _ in enGuess }
        let u = try await WhisperBatchTranscriber(core: core, gate: BatchGate(), windows: small, splitting: .perWindow, log: { _ in })
            .transcribe(file: try wavFile(silence(10) + tone(6) + silence(24)), language: .auto, hints: [], progress: { _ in })
        let first = try #require(core.detections.first)
        #expect(core.detections.count == 1)   // 窓 2 は無音なので判定しない
        #expect(abs(Double(first.count) / 16_000 - (Double(core.requests[0].samples.count) / 16_000 - 9.8)) < 0.05)
        #expect(core.requests.map(\.language) == [.en, .en])
        #expect(u.map(\.text) == ["Hello"])
    }

    /// 判定の間も進捗が進み（窓の judgingShare = 4 割まで）、全体で単調に 1 まで届く。
    @Test func progressMovesWhileJudgingAndStaysMonotonic() async throws {
        let core = FakeWhisperCore(windows: [[seg(0, 8, "Hello")], [seg(0.5, 8.5, "こんにちは")]])
        core.guess = { s in s.count < 9 * 16_000 ? enGuess : jaGuess }
        let box = ProgressBox()
        _ = try await run(core, tone(8) + silence(1) + tone(9), language: .auto, progress: { box.append($0) })
        let values = box.values
        #expect(values.contains { $0 > 0 && $0 <= WhisperBatchTranscriber.judgingShare + 1e-9 })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == 1.0)
    }
}
