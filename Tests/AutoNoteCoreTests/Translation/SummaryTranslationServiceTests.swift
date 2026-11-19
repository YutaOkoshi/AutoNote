@testable import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

/// The summaries' translation after the recording (spec 2026-11-19 いつ訳すか・録音後).
@Suite struct SummaryTranslationServiceTests {
    private func queue(_ items: [(String, String, String)]) -> QueueStatus {
        QueueStatus(items: items.map { QueueItemDTO(meetingID: $0.0, stage: $0.1, state: $0.2) })
    }

    private func writeMinutes(_ f: TranslationFixture, _ m: MinutesOutput = SummaryTranslationTests.minutes) throws {
        try FileManager.default.createDirectory(at: f.paths.transcriptsDirectory(f.id), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(m).write(to: f.paths.minutesFile(f.id), options: .atomic)
    }

    private func service(_ f: TranslationFixture, _ fake: FakeTextCompleter,
                         rewrites: Collected<MeetingID>? = nil) -> TranslationService {
        var deps = f.deps(fake)
        if let rewrites { deps.rewriteNote = { rewrites.append($0) } }
        return TranslationService(deps)
    }

    @Test func theMinutesAreTranslatedRightAfterTheTranscriptAndTheNoteIsRewritten() async throws {
        let f = try TranslationFixture()
        try writeMinutes(f)
        try LiveSummaryStore(paths: f.paths).save(SummaryTranslationTests.live, for: f.id)
        let minutesBefore = try Data(contentsOf: f.paths.minutesFile(f.id))
        let liveBefore = try Data(contentsOf: f.paths.liveSummaryFile(f.id))
        let fake = FakeTextCompleter()
        let rewrites = Collected<MeetingID>()
        let service = service(f, fake, rewrites: rewrites)
        try await service.translate(f.id)
        await service.waitForJob(f.id)

        let minutes = try #require(f.store.loadSummary(f.id, .minutes))
        #expect(minutes.translation(of: "移行は今月末までに終える") == "EN: 移行は今月末までに終える")
        #expect(minutes.entries.count == SummaryTranslation.minutesTexts(SummaryTranslationTests.minutes).count)
        #expect(minutes.model == "2b" && minutes.target == .auto)
        let live = try #require(f.store.loadSummary(f.id, .live))
        #expect(live.translation(of: "手順書を送る") == "EN: 手順書を送る")
        // The summaries themselves are never rewritten (spec 保存).
        #expect(try Data(contentsOf: f.paths.minutesFile(f.id)) == minutesBefore)
        #expect(try Data(contentsOf: f.paths.liveSummaryFile(f.id)) == liveBefore)
        #expect(rewrites.values == [f.id])
        // One lease for the transcript, one for the summaries; released at the end.
        #expect(fake.snapshot.loads.count == 2 && fake.snapshot.loaded == nil)
        // The meeting's translation carries both for the screens.
        let t = await service.meetingTranslation(f.id)
        #expect(t.minutes?.translation(of: "残りの手順書を送る") == "EN: 残りの手順書を送る")
        #expect(t.liveSummary?.translation(of: "テナント移行の進捗") == "EN: テナント移行の進捗")
    }

    @Test func minutesMadeAfterTheTranslationAreTranslatedWhenTheyAppear() async throws {
        let f = try TranslationFixture()
        let fake = FakeTextCompleter()
        let rewrites = Collected<MeetingID>()
        let service = service(f, fake, rewrites: rewrites)
        let (stream, continuation) = AsyncStream<QueueStatus>.makeStream()
        let follower = Task { await service.follow(queue: stream) }
        continuation.yield(queue([(f.id.rawValue, StageName.summarize, "running")]))
        #expect(await pollTranslation { f.store.load(f.id)?.complete == true })
        await service.waitForJob(f.id)
        #expect(f.store.loadSummary(f.id, .minutes) == nil)
        let transcriptPrompts = fake.snapshot.prompts.count

        try writeMinutes(f)
        continuation.yield(queue([(f.id.rawValue, StageName.writeVault, "running")]))
        #expect(await pollTranslation { f.store.loadSummary(f.id, .minutes) != nil })
        await service.waitForJob(f.id)
        let count = SummaryTranslation.minutesTexts(SummaryTranslationTests.minutes).count
        #expect(fake.snapshot.prompts.count == transcriptPrompts + count)
        #expect(rewrites.values == [f.id])

        // The same minutes are not translated again on the next status.
        continuation.yield(queue([]))
        try await Task.sleep(for: .milliseconds(30))
        await service.waitForJob(f.id)
        #expect(fake.snapshot.prompts.count == transcriptPrompts + count)

        // Regenerated minutes: only the changed item is translated.
        var redone = SummaryTranslationTests.minutes
        redone.decisions = [Decision(text: "移行は来月半ばまでに終える", t: "00:01:00")]
        try await Task.sleep(for: .milliseconds(20))   // a newer modification date
        try writeMinutes(f, redone)
        continuation.yield(queue([(f.id.rawValue, StageName.writeVault, "running")]))
        #expect(await pollTranslation { f.store.loadSummary(f.id, .minutes)?.translation(of: "移行は来月半ばまでに終える") != nil })
        await service.waitForJob(f.id)
        #expect(fake.snapshot.prompts.count == transcriptPrompts + count + 1)
        #expect(f.store.loadSummary(f.id, .minutes)?.translation(of: "移行は今月末までに終える") == nil)
        continuation.finish()
        await follower.value
    }

    /// Review M1: minutes written while the job translates the live summary (summarize finishing meanwhile, the item
    /// leaving the queue) are translated by the same job before it ends, and the note is rewritten.
    @Test func minutesWrittenWhileTheJobRunsAreTranslatedBeforeItEnds() async throws {
        let f = try TranslationFixture()
        try LiveSummaryStore(paths: f.paths).save(SummaryTranslationTests.live, for: f.id)
        let fx = f
        let fake = FakeTextCompleter(onCall: { call in
            if call == 1 { try? AutoNoteJSON.encoder().encode(SummaryTranslationTests.minutes).write(to: fx.paths.minutesFile(fx.id)) }
        })
        let rewrites = Collected<MeetingID>()
        let service = service(f, fake, rewrites: rewrites)
        await service.start(f.id, automatic: true, summariesOnly: true)
        await service.waitForJob(f.id)
        let minutes = try #require(f.store.loadSummary(f.id, .minutes))
        #expect(minutes.translation(of: "移行は今月末までに終える") == "EN: 移行は今月末までに終える")
        #expect(rewrites.values == [f.id])
        // Nothing left for a later status to start.
        let prompts = fake.snapshot.prompts.count
        await service.startSummariesIfDue(f.id)
        await service.waitForJob(f.id)
        #expect(fake.snapshot.prompts.count == prompts)
    }

    /// Review M2: 「訳し直す」 and a changed model redo the summaries like the transcript; an automatic run with the
    /// same model keeps them.
    @Test func aRetranslationOrANewModelRedoesTheSummaries() async throws {
        let f = try TranslationFixture()
        try writeMinutes(f)
        let fake = FakeTextCompleter()
        let service = service(f, fake)
        let decision = "移行は今月末までに終える"
        let asked = { fake.snapshot.prompts.filter { FakeTextCompleter.lastInput($0)?.text == decision }.count }
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        #expect(asked() == 1)
        // The same model, automatically: nothing again.
        await service.start(f.id, automatic: true, summariesOnly: true)
        await service.waitForJob(f.id)
        #expect(asked() == 1)
        // 「訳し直す」: the summaries are translated again from scratch.
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        #expect(asked() == 2)
        // Translated by another model (or revision): redone even automatically.
        var old = try #require(f.store.loadSummary(f.id, .minutes))
        old.modelRevision = "older"
        try f.store.saveSummary(old, .minutes, for: f.id)
        await service.start(f.id, automatic: true, summariesOnly: true)
        await service.waitForJob(f.id)
        #expect(asked() == 3)
        #expect(f.store.loadSummary(f.id, .minutes)?.modelRevision != "older")
    }

    @Test func nothingIsTranslatedWhenTheTargetIsTheSummarysOwnLanguage() async throws {
        let f = try TranslationFixture()
        f.settings.withLock { $0.translationTarget = .ja }
        try writeMinutes(f)
        let fake = FakeTextCompleter()
        let rewrites = Collected<MeetingID>()
        let service = service(f, fake, rewrites: rewrites)
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        #expect(f.store.loadSummary(f.id, .minutes) == nil)
        #expect(!fake.snapshot.prompts.contains { $0.contains("移行は今月末までに終える") })
        #expect(rewrites.values.isEmpty)
    }

    @Test func minutesAreNotTranslatedAutomaticallyWhenTheModeIsOff() async throws {
        let f = try TranslationFixture(mode: .off)
        let fake = FakeTextCompleter()
        let service = service(f, fake)
        try writeMinutes(f)
        await service.startSummariesIfDue(f.id)
        await service.waitForJob(f.id)
        #expect(fake.snapshot.prompts.isEmpty)
        #expect(f.store.loadSummary(f.id, .minutes) == nil)
    }

    @Test func theMinutesWaitWhileRecording() async throws {
        let f = try TranslationFixture()
        try writeMinutes(f)
        // The transcript is done already, so the job goes straight to the minutes.
        let fake = FakeTextCompleter()
        let first = service(f, fake)
        try await first.translate(f.id)
        await first.waitForJob(f.id)
        try f.store.saveSummary(SummaryTranslationDocument(model: "2b", modelRevision: "", target: .auto,
                                                           updatedAt: Date()), .minutes, for: f.id)
        let before = fake.snapshot.prompts.count
        let service = service(f, fake)
        await service.setRecording(true)
        await service.startSummariesIfDue(f.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.snapshot.prompts.count == before)
        await service.setRecording(false)
        #expect(await pollTranslation { (f.store.loadSummary(f.id, .minutes)?.entries.count ?? 0) > 0 })
        await service.waitForJob(f.id)
    }
}
