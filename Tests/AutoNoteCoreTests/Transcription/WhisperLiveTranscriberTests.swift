import AutoNoteCore
import AutoNoteTestSupport
import Synchronization
import Testing

private final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { line in self.lines.withLock { $0.append(line) } } }
}

@Suite struct WhisperLiveTranscriberTests {
    private func feed(_ t: WhisperLiveTranscriber, _ samples: [Int16], at start: Double) async {
        for c in PCMAudio.chunks(samples, track: .mic, chunkSeconds: 0.1, start: TimelineTime(seconds: start)) { await t.feed(c) }
    }

    @Test func emitsPartialThenFinalWithSameStart() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); let t = WhisperLiveTranscriber(core: core)
        let s = try await t.start(language: .ja, hints: [])
        for c in PCMAudio.chunks(tone(3) + silence(1), track: .mic, chunkSeconds: 0.1, start: TimelineTime(seconds: 100)) { await t.feed(c) }
        await t.finish(); let all = await collect(s)
        #expect(all.first { !$0.isFinal }?.start.seconds == 100); #expect(all.last?.isFinal == true); #expect(all.last?.start.seconds == 100)
        #expect(all.last?.end?.seconds == 103)
        #expect(all.last?.text == "テスト")
        #expect(all.allSatisfy { $0.speaker == .unknown })
        #expect(core.requests.allSatisfy { $0.mode == .live && $0.offsetSeconds == 0 })
    }

    @Test func timelineGapAfterPause() async throws {
        let t = WhisperLiveTranscriber(core: FakeWhisperCore(fixedText: "テスト"))
        let s = try await t.start(language: .ja, hints: [])
        await feed(t, tone(3) + silence(1), at: 0)
        await feed(t, tone(3) + silence(1), at: 60)
        await t.finish()
        let finals = await collect(s).filter(\.isFinal)
        #expect(finals.count == 2)
        #expect(abs((finals.last?.start.seconds ?? 0) - 60) <= 0.05)
    }

    @Test func hardCutDropsOverlapTokensInNextWindow() async throws {
        let t = WhisperLiveTranscriber(core: FakeWhisperCore(fixedText: "テスト"))
        let s = try await t.start(language: .ja, hints: [])
        await feed(t, tone(10), at: 0)
        await t.finish()
        let finals = await collect(s).filter(\.isFinal)
        #expect(finals.map(\.text) == ["テスト", ""])         // 2 つ目の窓は先頭 1 秒のトークンを落とす → 空の確定
        #expect(finals.map(\.start.seconds) == [0, 7])
        #expect(finals.map { $0.end?.seconds } == [8, 10])
    }

    @Test func feedBeforeStartIsIgnored() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); let t = WhisperLiveTranscriber(core: core)
        await feed(t, tone(3) + silence(1), at: 0)
        let s = try await t.start(language: .ja, hints: [])
        await t.finish()
        #expect(await collect(s).isEmpty)
        #expect(core.runCount == 0)
    }

    @Test func decodeFailureStillEmitsEmptyFinal() async throws {
        let t = WhisperLiveTranscriber(core: FakeWhisperCore(failure: TranscriptionError.whisperFailed(-1)))
        let s = try await t.start(language: .ja, hints: [])
        await feed(t, tone(3) + silence(1), at: 0)
        await t.finish()
        let all = await collect(s)
        #expect(all == [Utterance(start: TimelineTime(seconds: 0), end: TimelineTime(seconds: 3), speaker: .unknown, text: "", isFinal: true)])
    }

    @Test func secondStartThrows() async throws {
        let t = WhisperLiveTranscriber(core: FakeWhisperCore(fixedText: "テスト"))
        _ = try await t.start(language: .ja, hints: [])
        await #expect(throws: TranscriptionError.engineUnavailable("already started")) { try await t.start(language: .ja, hints: []) }
    }

    @Test func finishIsIdempotent() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); let t = WhisperLiveTranscriber(core: core)
        let s = try await t.start(language: .ja, hints: [])
        await feed(t, tone(3) + silence(1), at: 0)
        async let first: Void = t.finish()
        async let second: Void = t.finish()
        _ = await (first, second)
        await t.finish()
        let finals = await collect(s).filter(\.isFinal)
        #expect(finals.map(\.text) == ["テスト"])
    }

    /// その言語で出てよい文字種にデコーダの語彙を絞る（ja でキリル文字などが混ざるのを防ぐ）。自動は日本語か英語なので日本語と同じ。
    @Test(arguments: [(Language.ja, ScriptRestriction.japanese), (.en, .english), (.auto, .japanese)])
    func requestCarriesTheScriptRestrictionOfTheLanguage(language: Language, expected: ScriptRestriction) async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); let t = WhisperLiveTranscriber(core: core)
        let s = try await t.start(language: language, hints: [])
        await feed(t, tone(3) + silence(1), at: 0)
        await t.finish(); _ = await collect(s)
        #expect(!core.requests.isEmpty)
        #expect(core.requests.allSatisfy { $0.scripts == expected })
    }

    // MARK: - Backlog (a decoder slower than the audio). No clock: the fake decoder waits until it is released.

    /// One utterance that ends in silence: one commit (3 s of audio in a 4 s stretch).
    private func speak(_ t: WhisperLiveTranscriber, _ count: Int, from first: Int = 0) async {
        for i in first..<(first + count) { await feed(t, tone(3) + silence(1), at: Double(i) * 4) }
    }

    private func finals(_ iterator: inout AsyncStream<Utterance>.Iterator, _ count: Int) async {
        var seen = 0
        while seen < count, let u = await iterator.next() { if u.isFinal { seen += 1 } }
    }

    @Test func aBacklogOverThreeCommitsIsLoggedAndAgainEachTimeItDoubles() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); core.hold()
        let log = LogLines(); let t = WhisperLiveTranscriber(core: core, log: log.sink)
        let s = try await t.start(language: .ja, hints: [])
        await speak(t, 3)
        #expect(log.all.isEmpty)                                    // 3 件までは出さない
        await speak(t, 1, from: 3)
        // 4 件目の確定の終わり（15 秒）− 復号中の窓の終わり（3 秒）: 先頭の窓の後ろで待っている音声
        #expect(log.all == ["live backlog: track=mic depth=4 lag=12.0s"])
        await speak(t, 3, from: 4)
        #expect(log.all.count == 1)                                 // 5〜7 件では出さない
        await speak(t, 1, from: 7)
        #expect(log.all == ["live backlog: track=mic depth=4 lag=12.0s", "live backlog: track=mic depth=8 lag=28.0s"])
        #expect(await t.worstBacklog == .init(depth: 8, lagSeconds: 28))
        core.release(); await t.finish()
        #expect(await collect(s).filter(\.isFinal).count == 8)      // 何も捨てない
        // 停止の行の depth と lag は、止めた時点までにどこまで復号が進んだかで変わる。最大値は変わらない
        #expect(log.all.count { $0.hasPrefix("live backlog at stop: track=mic depth=") && $0.hasSuffix(" max_depth=8 max_lag=28.0s") } == 1)
        #expect(log.all.contains("live backlog cleared: track=mic max_depth=8 max_lag=28.0s"))
        #expect(log.all.count == 4)
        #expect(log.all.allSatisfy { !$0.contains("テスト") })       // 本文は出さない
    }

    @Test func aBacklogOfThreeCommitsIsNotLogged() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); core.hold()
        let log = LogLines(); let t = WhisperLiveTranscriber(core: core, log: log.sink)
        let s = try await t.start(language: .ja, hints: [])
        await speak(t, 3)
        core.release(); await t.finish(); _ = await collect(s)
        #expect(log.all.count == 1)                                 // 停止の 1 行だけ
        #expect(log.all.first?.hasPrefix("live backlog at stop: track=mic depth=") == true)
        #expect(log.all.first?.hasSuffix(" max_depth=3 max_lag=8.0s") == true)
    }

    /// 待ちが無ければ遅れは 0。復号中の 1 件は深さに数えるが、その後ろに何も無ければ遅れではない。
    @Test func nothingWaitingBehindTheWindowInWorkIsNoLag() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); core.hold()
        let log = LogLines(); let t = WhisperLiveTranscriber(core: core, log: log.sink)
        let s = try await t.start(language: .ja, hints: [])
        await speak(t, 1)                                           // 0〜3 秒を復号中、待ちなし
        #expect(await t.worstBacklog == .init(depth: 1, lagSeconds: 0))
        await speak(t, 1, from: 1)                                  // 4〜7 秒が後ろで待つ: 7 − 3
        #expect(await t.worstBacklog == .init(depth: 2, lagSeconds: 4))
        core.release(); await t.finish(); _ = await collect(s)
    }

    /// 追いついている復号: 確定を 1 件ずつ読み切ってから次を話す。停止の行は出るが、遅れは 0 のまま。
    @Test func aDecoderThatKeepsUpReportsNoLagAtStop() async throws {
        let core = FakeWhisperCore(fixedText: "テスト")
        let log = LogLines(); let t = WhisperLiveTranscriber(core: core, log: log.sink)
        let s = try await t.start(language: .ja, hints: [])
        var results = s.makeAsyncIterator()
        for i in 0..<3 { await speak(t, 1, from: i); await finals(&results, 1) }
        await t.finish()
        #expect(log.all == ["live backlog at stop: track=mic depth=0 lag=0.0s max_depth=1 max_lag=0.0s"])
    }

    /// 停止の行は、残りの復号を待たずに `inputEnded()` の時点で出る（`LiveFeed` が両トラックに先に知らせる）。
    @Test func inputEndedWritesTheStopLineWithoutWaitingForTheDecoder() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); core.hold()
        let log = LogLines(); let t = WhisperLiveTranscriber(core: core, log: log.sink)
        let s = try await t.start(language: .ja, hints: [])
        await speak(t, 4)
        await t.inputEnded()                                        // 復号は止めたまま
        #expect(log.all.last == "live backlog at stop: track=mic depth=4 lag=12.0s max_depth=4 max_lag=12.0s")
        await speak(t, 1, from: 4)                                  // 終わりを告げた後の音声は受け取らない
        await t.inputEnded()
        core.release(); await t.finish()
        #expect(await collect(s).filter(\.isFinal).count == 4)
        #expect(log.all.count { $0.hasPrefix("live backlog at stop:") } == 1)   // finish は書き直さない
    }

    @Test func theBacklogIsCountedAgainOnceTheQueueIsEmpty() async throws {
        let core = FakeWhisperCore(fixedText: "テスト"); core.hold()
        let log = LogLines(); let t = WhisperLiveTranscriber(core: core, log: log.sink)
        let s = try await t.start(language: .ja, hints: [])
        var results = s.makeAsyncIterator()
        await speak(t, 8)
        core.release(); await finals(&results, 8)                   // 列が空に戻るまで待つ
        #expect(log.all == ["live backlog: track=mic depth=4 lag=12.0s", "live backlog: track=mic depth=8 lag=28.0s",
                            "live backlog cleared: track=mic max_depth=8 max_lag=28.0s"])
        core.hold()
        await speak(t, 3, from: 8)
        #expect(log.all.count == 3)
        await speak(t, 1, from: 11)                                 // 数え直して 4 件目で出る
        #expect(log.all.last == "live backlog: track=mic depth=4 lag=12.0s")
        core.release(); await finals(&results, 4)
        // 解消の行はその山の最大（4 件）。録音全体の最大（8 件）は停止の行にだけ出る
        #expect(log.all.last == "live backlog cleared: track=mic max_depth=4 max_lag=12.0s")
        await t.finish()
        #expect(log.all.last == "live backlog at stop: track=mic depth=0 lag=0.0s max_depth=8 max_lag=28.0s")
    }
}
