@testable import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct LiveTranslationBacklogTests {
    @Test func keepsEverythingWithinTheLimit() {
        let r = LiveTranslationBacklog.select([1, 2], limit: 2)
        #expect(r.translate == [1, 2] && r.skip.isEmpty)
    }

    @Test func skipsTheOlderLinesWhenBehind() {
        let r = LiveTranslationBacklog.select([1, 2, 3, 4, 5], limit: 2)
        #expect(r.translate == [4, 5] && r.skip == [1, 2, 3])
    }
}

@Suite struct LiveTranslatorTests {
    private func partial(_ s: Double, _ text: String) -> Utterance {
        Utterance(start: TimelineTime(seconds: s), speaker: .other, text: text, isFinal: false)
    }

    private func start(_ f: TranslationFixture, _ fake: FakeTextCompleter,
                       profile: MachineProfile = .init(kind: .appleSilicon, physicalCores: 8, physicalMemory: 32 << 30))
        async -> (LiveTranslator, AsyncStream<[Utterance]>.Continuation, Collected<TranslationUpdate>, Task<Void, Never>) {
        let broadcaster = TranslationBroadcaster()
        let (updates, _) = Collected.from(broadcaster.subscribe())
        let translator = LiveTranslator(f.deps(fake, profile: profile), broadcaster: broadcaster)
        let (feeds, feedsContinuation) = AsyncStream<LiveConfirmedFeed>.makeStream()
        let (lists, listContinuation) = AsyncStream<[Utterance]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        feedsContinuation.yield(LiveConfirmedFeed(meetingID: f.id, utterances: lists))
        feedsContinuation.finish()
        let runner = Task { await translator.run(feeds: feeds) }
        return (translator, listContinuation, updates, runner)
    }

    @Test func translatesConfirmedLinesInOrderAndSavesThem() async throws {
        let f = try TranslationFixture(mode: .duringRecording)
        let fake = FakeTextCompleter()
        let (translator, lists, updates, runner) = await start(f, fake)
        let a = utterance(0, "We moved the tenants.")
        let b = utterance(3, "残りはいつですか。", .me)
        lists.yield([a])
        #expect(await eventually { fake.snapshot.prompts.count == 1 })
        lists.yield([a, b, partial(6, "And the")])
        #expect(await eventually { updates.values.count == 2 })
        lists.finish()
        await runner.value
        await translator.waitForSessions()
        #expect(updates.values == [
            .live(f.id, LiveTranslatedLine(key: TranslationKey.live(a), sourceLanguage: .en, targetLanguage: .ja,
                                           text: "JA: We moved the tenants.")),
            .live(f.id, LiveTranslatedLine(key: TranslationKey.live(b), sourceLanguage: .ja, targetLanguage: .en,
                                           text: "EN: 残りはいつですか。")),
        ])
        // Only confirmed lines; the second prompt carries the first pair as history.
        #expect(fake.snapshot.prompts.count == 2)
        #expect(fake.snapshot.prompts[1].contains("JA: We moved the tenants."))
        #expect(f.store.loadLive(f.id)?.lines.count == 2)
        // Loaded at the start, released when the feed ended.
        #expect(fake.snapshot.loads.count == 1 && fake.snapshot.loaded == nil)
    }

    @Test func catchesUpWithTheNewestWhenBehind() async throws {
        let f = try TranslationFixture(mode: .duringRecording)
        let all = (0..<10).map { utterance(Double($0 * 3), "Line number \($0).") }
        let lists = LockedBox<AsyncStream<[Utterance]>.Continuation?>(nil)
        // Nine more lines arrive while the first one is being translated.
        let fake = FakeTextCompleter(onCall: { n in if n == 1 { lists.withLock { $0 }?.yield(all) } })
        let (translator, continuation, updates, runner) = await start(f, fake)
        lists.withLock { $0 = continuation }
        continuation.yield([all[0]])
        #expect(await eventually { updates.values.count >= 3 })
        continuation.finish()
        await runner.value
        await translator.waitForSessions()
        let translated = updates.values.compactMap { if case .live(_, let l) = $0 { l.text } else { nil } }
        #expect(translated == ["JA: Line number 0.", "JA: Line number 8.", "JA: Line number 9."])
    }

    @Test func aSlowTranslatorNeverHoldsUpTheLiveTranscript() async throws {
        let f = try TranslationFixture(mode: .duringRecording)
        let fake = FakeTextCompleter(hang: true)
        let utterances = (0..<50).map { utterance(Double($0), "Line \($0).") }
        // The same kind of stream `LiveTranscriptionWiring` hands out (newest only): its producer must keep flowing.
        let broadcaster = TranslationBroadcaster()
        let translator = LiveTranslator(f.deps(fake), broadcaster: broadcaster)
        let (lists, listContinuation) = AsyncStream<[Utterance]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (feeds, feedsContinuation) = AsyncStream<LiveConfirmedFeed>.makeStream()
        feedsContinuation.yield(LiveConfirmedFeed(meetingID: f.id, utterances: lists))
        let runner = Task { await translator.run(feeds: feeds) }
        #expect(await eventually {
            listContinuation.yield([utterances[0]])
            return fake.snapshot.prompts.count == 1
        })
        // The translator is stuck inside the model; feeding 50 more lists must not block the producer.
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for n in 1..<utterances.count { listContinuation.yield(Array(utterances.prefix(n + 1))) }
        }
        #expect(elapsed < .milliseconds(100))
        listContinuation.finish()
        feedsContinuation.finish()
        runner.cancel()
        await runner.value
        await translator.waitForSessions()
        #expect(fake.snapshot.loaded == nil)
    }

    @Test func nothingUnlessTheModeIsDuringRecordingOnAppleSilicon() async throws {
        for (mode, profile) in [
            (TranslationMode.afterRecording, MachineProfile(kind: .appleSilicon, physicalCores: 8, physicalMemory: 32 << 30)),
            (.off, MachineProfile(kind: .appleSilicon, physicalCores: 8, physicalMemory: 32 << 30)),
            (.duringRecording, MachineProfile(kind: .intel, physicalCores: 4, physicalMemory: 32 << 30)),
        ] {
            let f = try TranslationFixture(mode: mode)
            let fake = FakeTextCompleter()
            let (translator, lists, updates, runner) = await start(f, fake, profile: profile)
            lists.yield([utterance(0, "Hello there.")])
            lists.finish()
            await runner.value
            await translator.waitForSessions()
            #expect(fake.snapshot.loads.isEmpty, "\(mode) \(profile.kind)")
            #expect(updates.values.isEmpty)
        }
    }

    @Test func aModelThatFailsToLoadOnlyEndsTheLiveTranslation() async throws {
        let f = try TranslationFixture(mode: .duringRecording)
        let fake = FakeTextCompleter(failLoad: true)
        let (translator, lists, updates, runner) = await start(f, fake)
        lists.yield([utterance(0, "Hello there.")])
        lists.finish()
        await runner.value
        await translator.waitForSessions()
        #expect(updates.values.isEmpty)
        #expect(f.store.loadLive(f.id) == nil)
    }
}
