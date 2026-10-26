import AutoNoteCore
import AutoNoteTestSupport
import Testing

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
}
