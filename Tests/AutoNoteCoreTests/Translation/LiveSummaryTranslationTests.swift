@testable import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

/// The live summary's translation while recording (spec 2026-11-19 いつ訳すか・録音中): inside the live translation's
/// session (one model), after the utterances, only the changed texts, the newest summary only.
@Suite struct LiveSummaryTranslationTests {
    private struct Running {
        let translator: LiveTranslator
        let lists: AsyncStream<[Utterance]>.Continuation
        let summaries: AsyncStream<LiveSummaryUpdate>.Continuation
        let updates: Collected<TranslationUpdate>
        let runner: Task<Void, Never>
        let follower: Task<Void, Never>

        func finish() async {
            lists.finish()
            await runner.value
            await translator.waitForSessions()
            summaries.finish()
            await follower.value
        }
    }

    private func start(_ f: TranslationFixture, _ fake: FakeTextCompleter) async -> Running {
        let broadcaster = TranslationBroadcaster()
        let (updates, _) = Collected.from(broadcaster.subscribe())
        let translator = LiveTranslator(f.deps(fake), broadcaster: broadcaster)
        let (summaries, summaryContinuation) = AsyncStream<LiveSummaryUpdate>.makeStream()
        let follower = Task { await translator.follow(summaries: summaries) }
        let (feeds, feedsContinuation) = AsyncStream<LiveConfirmedFeed>.makeStream()
        let (lists, listContinuation) = AsyncStream<[Utterance]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        feedsContinuation.yield(LiveConfirmedFeed(meetingID: f.id, utterances: lists))
        feedsContinuation.finish()
        let runner = Task { await translator.run(feeds: feeds) }
        return Running(translator: translator, lists: listContinuation, summaries: summaryContinuation,
                       updates: updates, runner: runner, follower: follower)
    }

    private func summary(_ now: String, _ decisions: [String]) -> LiveSummaryState {
        LiveSummaryState(now: now, decisions: decisions, todos: [], consumedThrough: 10, updatedAt: nil)
    }

    private func liveSummaryDocs(_ u: Collected<TranslationUpdate>) -> [SummaryTranslationDocument] {
        u.values.compactMap { if case .liveSummary(_, let d) = $0 { d } else { nil } }
    }

    @Test func eachUpdateTranslatesOnlyItsChangedTexts() async throws {
        let f = try TranslationFixture(mode: .duringRecording)
        let fake = FakeTextCompleter()
        let r = await start(f, fake)
        r.lists.yield([utterance(0, "移行の進捗を確認します。", .me)])
        #expect(await pollTranslation { fake.snapshot.prompts.count == 1 })
        r.summaries.yield(LiveSummaryUpdate(meetingID: f.id, state: summary("移行の進捗", ["月末までに終える"]), status: .active))
        #expect(await pollTranslation { f.store.loadSummary(f.id, .live)?.entries.count == 2 })
        r.summaries.yield(LiveSummaryUpdate(meetingID: f.id, state: summary("移行の進捗", ["月末までに終える", "応援を頼む"]),
                                            status: .active))
        #expect(await pollTranslation { f.store.loadSummary(f.id, .live)?.entries.count == 3 })
        await r.finish()
        // 1 utterance + 2 + 1 summary texts: the unchanged ones were not sent again.
        #expect(fake.snapshot.prompts.count == 4)
        let doc = try #require(f.store.loadSummary(f.id, .live))
        #expect(doc.translation(of: "応援を頼む") == "EN: 応援を頼む")
        #expect(liveSummaryDocs(r.updates).last == doc)
        // One model for the whole recording.
        #expect(fake.snapshot.loads.count == 1 && fake.snapshot.loaded == nil)
        // live-summary.json is the scheduler's alone: never written here.
        #expect(!FileManager.default.fileExists(atPath: f.paths.liveSummaryFile(f.id).path))
    }

    @Test func utterancesComeFirstAndOnlyTheNewestSummaryIsTranslated() async throws {
        let f = try TranslationFixture(mode: .duringRecording)
        let box = LockedBox<Running?>(nil)
        let first = summary("古い話題", ["古い決定その一", "古い決定その二"])
        let newest = summary("新しい話題", ["新しい決定"])
        let line = utterance(5, "New line while busy.")
        // While the first summary text is being translated, a new utterance and a newer summary arrive.
        let fake = FakeTextCompleter(onCall: { n in
            guard n == 2, let r = box.withLock({ $0 }) else { return }
            r.lists.yield([utterance(0, "最初の発話です。", .me), line])
            r.summaries.yield(LiveSummaryUpdate(meetingID: f.id, state: newest, status: .active))
            try? await Task.sleep(for: .milliseconds(30))
        })
        let r = await start(f, fake)
        box.withLock { $0 = r }
        r.lists.yield([utterance(0, "最初の発話です。", .me)])
        #expect(await pollTranslation { fake.snapshot.prompts.count == 1 })
        r.summaries.yield(LiveSummaryUpdate(meetingID: f.id, state: first, status: .active))
        #expect(await pollTranslation { f.store.loadSummary(f.id, .live)?.translation(of: "新しい決定") != nil })
        await r.finish()
        let inputs = fake.snapshot.prompts.compactMap { FakeTextCompleter.lastInput($0)?.text }
        // The new utterance goes right after the summary text in flight; the rest of the old summary is dropped.
        #expect(inputs == ["最初の発話です。", "古い話題", "New line while busy.", "新しい話題", "新しい決定"])
        let doc = try #require(f.store.loadSummary(f.id, .live))
        #expect(doc.translation(of: "古い決定その一") == nil)
        #expect(doc.translation(of: "古い話題") == nil)   // no longer in the summary
    }

    @Test func noSummaryTranslationOutsideDuringRecording() async throws {
        let f = try TranslationFixture(mode: .afterRecording)
        let fake = FakeTextCompleter()
        let r = await start(f, fake)
        r.summaries.yield(LiveSummaryUpdate(meetingID: f.id, state: summary("話題", ["決定"]), status: .active))
        r.lists.yield([utterance(0, "発話です。")])
        try await Task.sleep(for: .milliseconds(30))
        await r.finish()
        #expect(fake.snapshot.prompts.isEmpty)
        #expect(f.store.loadSummary(f.id, .live) == nil)
    }

    @Test func aSummaryAlreadyInTheTargetLanguageIsNotTranslated() async throws {
        let f = try TranslationFixture(mode: .duringRecording)
        f.settings.withLock { $0.translationTarget = .ja }
        let fake = FakeTextCompleter()
        let r = await start(f, fake)
        r.summaries.yield(LiveSummaryUpdate(meetingID: f.id, state: summary("移行の進捗", ["月末までに終える"]), status: .active))
        r.lists.yield([utterance(0, "We moved the tenants.")])
        #expect(await pollTranslation { fake.snapshot.prompts.count == 1 })
        try await Task.sleep(for: .milliseconds(30))
        await r.finish()
        #expect(fake.snapshot.prompts.count == 1)
        #expect(f.store.loadSummary(f.id, .live) == nil)
    }
}
