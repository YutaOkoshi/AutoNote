import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct SummarizeStageTests {
    private struct Fixture {
        let paths: AppPaths
        let manifests: ManifestStore
        let manifest: Manifest
        let outputFolder: URL
        let final: Transcript
    }

    /// A `.transcribed` meeting with `final.json`, plus an empty output folder.
    private func setUp(bookmarks: [Bookmark] = []) async throws -> Fixture {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        var manifest = Samples.manifest
        manifest.status = .transcribed
        manifest.bookmarks = bookmarks
        let manifests = ManifestStore(paths: paths)
        try await manifests.save(manifest)
        let final = Transcript(utterances: [u(1, .me, "はじめます")], engine: "whisper.cpp large-v3-turbo",
                               language: manifest.language)
        let url = paths.transcriptFile(manifest.id, .final)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(final).write(to: url)
        return Fixture(paths: paths, manifests: manifests, manifest: manifest,
                       outputFolder: try TemporaryDirectory.make(), final: final)
    }

    private func writePortable(_ f: Fixture, _ file: PortableFile, _ text: String) throws {
        let dir = f.outputFolder.appending(path: "_autonote", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appending(path: file.rawValue))
    }

    private func stage(_ summarizer: ScriptedSummarizer) -> SummarizeStage {
        SummarizeStage(summarizer: { _, _ in summarizer }, services: SharedVaultServices())
    }

    private func context(_ f: Fixture) -> StageContext {
        var settings = Settings()
        settings.outputFolder = f.outputFolder.path
        return StageContext(paths: f.paths, settings: settings, manifests: f.manifests,
                            now: { Date(timeIntervalSince1970: 1_800_000_000) }, reportProgress: { _ in })
    }

    private func job(_ f: Fixture) -> Job {
        Job(id: f.manifest.id.rawValue, meeting: f.manifest.id, stages: StageName.all,
            completedStages: [StageName.transcribe], state: .running, attempts: 0, lastError: nil,
            notBefore: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func readMinutes(_ f: Fixture) throws -> MinutesOutput {
        try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(contentsOf: f.paths.minutesFile(f.manifest.id)))
    }

    @Test func nameIsSummarize() {
        #expect(SummarizeStage().name == "summarize")
    }

    @Test func buildsInputFromPromptDictionaryAndBookmarks() async throws {
        let bookmark = Bookmark(at: TimelineTime(seconds: 754), note: "大事")
        let f = try await setUp(bookmarks: [bookmark])
        try writePortable(f, .prompt, "独自の指示")
        try writePortable(f, .dictionary,
                          DictionaryFile(terms: ["ルミナ茶"], replacements: [], fillers: []).render())
        let scripted = ScriptedSummarizer(results: [.success(Samples.minutes)])
        var j = job(f)
        try await stage(scripted).run(&j, context: context(f))
        let inputs = await scripted.inputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.instructions == "独自の指示")
        #expect(inputs.first?.terms == ["ルミナ茶"])
        #expect(inputs.first?.bookmarks == [bookmark])
        #expect(inputs.first?.transcript == f.final)
        #expect(inputs.first?.language == f.manifest.language)
    }

    @Test func emptyPromptFileUsesDefault() async throws {
        let f = try await setUp()
        try writePortable(f, .prompt, "  \n")
        let scripted = ScriptedSummarizer(results: [.success(Samples.minutes)])
        var j = job(f)
        try await stage(scripted).run(&j, context: context(f))
        #expect(await scripted.inputs.first?.instructions == DefaultPrompt.instructions)
    }

    @Test func successWritesMinutesJsonAndClearsFailure() async throws {
        let f = try await setUp()
        let scripted = ScriptedSummarizer(results: [.success(Samples.minutes)])
        var j = job(f)
        j.summaryFailure = SummaryFailureKind.encode(.rateLimited, message: "earlier")
        try await stage(scripted).run(&j, context: context(f))
        #expect(try readMinutes(f) == Samples.minutes)
        #expect(j.summaryFailure == nil)
        #expect(try await f.manifests.load(f.manifest.id).title == nil)
    }

    @Test func setsGeneratingBeforeSummarizing() async throws {
        let f = try await setUp()
        let scripted = ScriptedSummarizer(results: [.success(Samples.minutes)])
        let manifests = f.manifests
        let id = f.manifest.id
        let probe = StatusProbe()
        let stage = SummarizeStage(summarizer: { _, _ in
            await probe.record(try? await manifests.load(id).status)
            return scripted
        }, services: SharedVaultServices())
        var j = job(f)
        try await stage.run(&j, context: context(f))
        #expect(await probe.statuses == [.generating])
    }

    @Test func rateLimitIsRecordedAndStageSucceeds() async throws {
        let f = try await setUp()
        let scripted = ScriptedSummarizer(results: [.failure(.rateLimited(message: "hit your limit"))])
        var j = job(f)
        try await stage(scripted).run(&j, context: context(f))
        #expect(SummaryFailureKind.of(j.summaryFailure) == .rateLimited)
        #expect(j.summaryFailure?.contains("hit your limit") == true)
    }

    @Test func notLoggedInIsRecorded() async throws {
        let f = try await setUp()
        let scripted = ScriptedSummarizer(results: [.failure(.notLoggedIn)])
        var j = job(f)
        try await stage(scripted).run(&j, context: context(f))
        #expect(SummaryFailureKind.of(j.summaryFailure) == .notLoggedIn)
    }

    @Test(arguments: [
        (SummarizerError.claudeNotFound(path: ""), SummaryFailureKind.claudeNotFound),
        (.contextExceeded(message: "too long"), .contextExceeded),
        (.timedOut, .timedOut),
        (.invalidOutput(message: "bad"), .invalidOutput),
        (.failed(exitCode: 2, message: "x"), .other),
    ])
    func failureKindsMapOneToOne(error: SummarizerError, kind: SummaryFailureKind) async throws {
        let f = try await setUp()
        var j = job(f)
        try await stage(ScriptedSummarizer(results: [.failure(error)])).run(&j, context: context(f))
        #expect(SummaryFailureKind.of(j.summaryFailure) == kind)
    }

    @Test func factoryErrorIsRecordedAsFailure() async throws {
        let f = try await setUp()
        let stage = SummarizeStage(summarizer: { _, _ in throw SummarizerError.claudeNotFound(path: "") },
                                   services: SharedVaultServices())
        var j = job(f)
        try await stage.run(&j, context: context(f))
        #expect(SummaryFailureKind.of(j.summaryFailure) == .claudeNotFound)
    }

    @Test func failedRegenerateKeepsExistingMinutes() async throws {
        let f = try await setUp()
        var previous = Samples.minutes
        previous.title = "前回"
        try AutoNoteJSON.encoder().encode(previous).write(to: f.paths.minutesFile(f.manifest.id))
        let scripted = ScriptedSummarizer(results: [.failure(.failed(exitCode: 1, message: "x"))])
        var j = job(f)
        try await stage(scripted).run(&j, context: context(f))
        #expect(try readMinutes(f).title == "前回")
        #expect(SummaryFailureKind.of(j.summaryFailure) == .other)
    }

    @Test func missingFinalTranscriptFails() async throws {
        let f = try await setUp()
        try FileManager.default.removeItem(at: f.paths.transcriptFile(f.manifest.id, .final))
        let scripted = ScriptedSummarizer(results: [.success(Samples.minutes)])
        var j = job(f)
        await #expect(throws: StageError.self) { try await stage(scripted).run(&j, context: context(f)) }
        #expect(await scripted.inputs.isEmpty)
    }

    @Test func factoryUsesConfiguredClaudePath() async throws {
        var settings = Settings()
        settings.claudePath = "/opt/fake/claude"
        settings.claudeModel = "sonnet"
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let summarizer = try await SummarizerFactory.make(settings: settings, paths: paths)
        let claude = try #require(summarizer as? ClaudeCodeSummarizer)
        #expect(claude.claudePath == "/opt/fake/claude")
        #expect(claude.model == "sonnet")
        #expect(claude.workingDirectory == paths.claudeWorkingDirectory)
    }
}

private actor StatusProbe {
    var statuses: [MeetingStatus?] = []
    func record(_ status: MeetingStatus?) { statuses.append(status) }
}
