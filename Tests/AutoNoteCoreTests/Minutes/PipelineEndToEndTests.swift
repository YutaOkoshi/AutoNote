import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

/// The standard stages end to end, with fake transcription and summarization (spec §8).
@Suite struct PipelineEndToEndTests {
    private static let titledPath = "2026/2026-10-24_1400_プロジェクト定例.md"
    private static let untitledPath = "2026/2026-10-24_140000.md"

    private struct Fixture {
        let paths: AppPaths
        let manifests: ManifestStore
        let jobs: JobStore
        let outputFolder: URL
        let clock = FakeQueueClock()
        let services = SharedVaultServices()
        var id: MeetingID { Samples.manifest.id }

        func file(_ relative: String) -> URL { outputFolder.appending(path: relative) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: file(relative).path) }
        func read(_ relative: String) throws -> String { try String(contentsOf: file(relative), encoding: .utf8) }
        func job() async throws -> Job? { try await jobs.load(id) }
        func status() async throws -> MeetingStatus { try await manifests.load(id).status }

        func runner() -> FinalTranscriptionRunner {
            FinalTranscriptionRunner(
                transcriber: FakeBatchTranscriber(results: ["mic-0.wav": [u(5, .unknown, "はじめます")]]),
                engineName: "whisper.cpp large-v3-turbo", paths: paths, gate: BatchGate())
        }

        func queue(summarizer: @escaping @Sendable (Settings, AppPaths) async throws -> any Summarizer)
            -> PostProcessingQueue {
            let stages = PostProcessingPipeline.standardStages(runner: runner(), summarizer: summarizer,
                                                               timeZone: Samples.tokyo, services: services)
            return PostProcessingQueue(paths: paths, stages: stages, activity: FakeRecordingActivity(),
                                       gate: BatchGate(), clock: clock, services: services)
        }
    }

    /// A meeting with one silent mic track in `status`, and `Settings.outputFolder` saved.
    /// `createOutputFolder: false` points the setting at a folder that does not exist yet.
    private func setUp(status: MeetingStatus = .recorded, createOutputFolder: Bool = true) async throws -> Fixture {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        var manifest = Samples.manifest
        manifest.status = status
        let tracksDir = paths.tracksDirectory(manifest.id)
        try FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try PCMAudio.writeWAV(Array(repeating: 0, count: 16_000), to: tracksDir.appending(path: "mic-000.wav"))
        manifest.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav",
                                     startOffset: TimelineTime(seconds: 0), durationSeconds: 1)]
        let manifests = ManifestStore(paths: paths)
        try await manifests.save(manifest)

        var outputFolder = try TemporaryDirectory.make()
        if !createOutputFolder {
            outputFolder = outputFolder.appending(path: "Vault", directoryHint: .isDirectory)
        }
        var settings = Settings()
        settings.outputFolder = outputFolder.path
        try await SettingsStore(paths: paths).save(settings)
        return Fixture(paths: paths, manifests: manifests, jobs: JobStore(paths: paths), outputFolder: outputFolder)
    }

    private static func fixed(_ result: Result<MinutesOutput, FakeError>)
        -> @Sendable (Settings, AppPaths) async throws -> any Summarizer {
        let summarizer = FakeSummarizer(result: result)
        return { _, _ in summarizer }
    }

    private static let succeeding = fixed(.success(Samples.minutes))

    @Test func recordedMeetingBecomesMinutesFileAndIndexRow() async throws {
        let f = try await setUp()
        let queue = f.queue(summarizer: Self.succeeding)
        await queue.enqueue(f.id)
        await queue.runUntilIdle()

        let text = try f.read(Self.titledPath)
        #expect(text.contains("status: minutes_generated"))
        #expect(text.contains("^t00-00-05"))
        let index = try f.read("_index.md")
        #expect(index.components(separatedBy: "[[2026/2026-10-24_1400_プロジェクト定例]]").count == 2)
        let job = try #require(try await f.job())
        #expect(job.state == .done)
        #expect(job.completedStages == [StageName.transcribe, StageName.summarize, StageName.writeVault,
                                        StageName.updateIndex, StageName.automations])
        #expect(try await f.status() == .minutesGenerated)
    }

    @Test func summaryFailureProducesTranscriptOnlyThenRegenerateRenames() async throws {
        let f = try await setUp()
        let failing = f.queue(summarizer: Self.fixed(.failure(FakeError(message: "x"))))
        await failing.enqueue(f.id)
        await failing.runUntilIdle()

        #expect(try f.read(Self.untitledPath).contains("status: transcript_only"))
        #expect(try f.read("_index.md").contains("[[2026/2026-10-24_140000]]"))
        #expect(try await f.status() == .transcriptOnly)
        #expect(try #require(try await f.job()).generation == 0)

        let queue = f.queue(summarizer: Self.succeeding)
        await queue.regenerate(f.id)
        await queue.runUntilIdle()

        #expect(try f.read(Self.titledPath).contains("status: minutes_generated"))
        #expect(!f.exists(Self.untitledPath))
        let index = try f.read("_index.md")
        #expect(index.contains("[[2026/2026-10-24_1400_プロジェクト定例]]"))
        #expect(!index.contains("[[2026/2026-10-24_140000]]"))
        let job = try #require(try await f.job())
        #expect(job.generation == 1)
        #expect(job.state == .done)
        #expect(job.summaryFailure == nil)
        #expect(try await f.status() == .minutesGenerated)
    }

    @Test func failedRegenerateRestoresMinutesGeneratedStatusAndKeepsNote() async throws {
        let f = try await setUp()
        let first = f.queue(summarizer: Self.succeeding)
        await first.enqueue(f.id)
        await first.runUntilIdle()
        let before = try f.read(Self.titledPath)
        #expect(try await f.status() == .minutesGenerated)

        // SummarizeStage marks the meeting `.generating`, fails, and WriteVaultStage keeps the existing note.
        let queue = f.queue(summarizer: Self.fixed(.failure(FakeError(message: "x"))))
        await queue.regenerate(f.id)
        await queue.runUntilIdle()

        #expect(try f.read(Self.titledPath) == before)
        #expect(!f.exists(Self.untitledPath))
        let job = try #require(try await f.job())
        #expect(job.generation == 1)
        #expect(job.summaryFailure != nil)
        #expect(try await f.status() == .minutesGenerated)
    }

    @Test func regenerateWithoutJobStartsFromSummarize() async throws {
        let f = try await setUp()
        let first = f.queue(summarizer: Self.succeeding)
        await first.enqueue(f.id)
        await first.runUntilIdle()
        try FileManager.default.removeItem(at: f.paths.queueJobsDirectory.appending(path: "\(f.id.rawValue).json"))

        let calls = CallLog()
        let queue = f.queue(summarizer: Self.succeeding)
        await queue.register(ScriptedStage(name: StageName.transcribe, log: calls))
        await queue.regenerate(f.id)
        await queue.runUntilIdle()

        #expect(await calls.entries.isEmpty)
        let job = try #require(try await f.job())
        #expect(job.state == .done)
        #expect(job.generation == 1)
        #expect(f.exists(Self.titledPath))
    }

    @Test func rateLimitedSummaryRetriesAfterOneHour() async throws {
        let f = try await setUp()
        let scripted = ScriptedSummarizer(results: [.failure(.rateLimited(message: "x")), .success(Samples.minutes)])
        let queue = f.queue(summarizer: { _, _ in scripted })
        await queue.enqueue(f.id)
        await queue.runUntilIdle()

        #expect(try f.read(Self.untitledPath).contains("status: transcript_only"))
        let waiting = try #require(try await f.job())
        #expect(waiting.state == .waiting)
        #expect(waiting.generation == 0)

        f.clock.advance(by: 3599)
        await queue.runUntilIdle()
        #expect(f.exists(Self.untitledPath))
        #expect(!f.exists(Self.titledPath))
        #expect(try #require(try await f.job()).generation == 0)

        f.clock.advance(by: 1)
        await queue.runUntilIdle()
        #expect(try f.read(Self.titledPath).contains("status: minutes_generated"))
        #expect(!f.exists(Self.untitledPath))
        let job = try #require(try await f.job())
        #expect(job.generation == 1)
        #expect(job.state == .done)
    }

    @Test func registeredAutomationsStageRunsLast() async throws {
        let f = try await setUp()
        let log = CallLog()
        let queue = f.queue(summarizer: Self.succeeding)
        await queue.register(ScriptedStage(name: StageName.automations, log: log))
        await queue.enqueue(f.id)
        await queue.runUntilIdle()

        #expect(await log.entries == [StageName.automations])
        #expect(f.exists(Self.titledPath))
        #expect(f.exists("_index.md"))
        #expect(try #require(try await f.job()).state == .done)
    }

    @Test func standardStagesAreTheFourInOrder() {
        let stages = PostProcessingPipeline.standardStages(runner: FinalTranscriptionRunner(
            transcriber: FakeBatchTranscriber(results: [:]), engineName: "x",
            paths: AppPaths(root: URL(filePath: "/tmp/unused")), gate: BatchGate()))
        #expect(stages.map(\.name) == ["transcribe", "summarize", "write_vault", "update_index"])
        #expect(UpdateIndexStage().name == "update_index")
    }

    @Test func standardStagesAcceptResolver() {
        let stages = PostProcessingPipeline.standardStages(resolveRunner: { _ in nil })
        #expect(stages.map(\.name) == [StageName.transcribe, StageName.summarize, StageName.writeVault,
                                         StageName.updateIndex])
    }

    @Test func acceptShortRecordingEnqueues() async throws {
        let f = try await setUp(status: .tooShort)
        let queue = f.queue(summarizer: Self.succeeding)
        await queue.enqueue(f.id)
        #expect(try await f.job() == nil)

        try await queue.acceptShortRecording(f.id)
        #expect(try await f.job() != nil)
        await queue.runUntilIdle()
        #expect(try #require(try await f.job()).state == .done)
        #expect(try await f.status() == .minutesGenerated)

        let other = try await setUp(status: .recorded)
        let otherQueue = other.queue(summarizer: Self.succeeding)
        await #expect(throws: QueueError.notTooShort(.recorded)) {
            try await otherQueue.acceptShortRecording(other.id)
        }
        #expect(try await other.job() == nil)
        #expect(try await other.status() == .recorded)
    }

    @Test func regenerateWithoutTranscriptDoesNothing() async throws {
        let f = try await setUp()
        let queue = f.queue(summarizer: Self.succeeding)
        await queue.regenerate(f.id)
        #expect(try await f.job() == nil)

        // An existing job (here: transcribe failed outright, so no final.json) keeps its generation.
        let failingRunner = FinalTranscriptionRunner(transcriber: FakeBatchTranscriber(results: [:]),
                                                     engineName: "x", paths: f.paths, gate: BatchGate())
        await queue.register(TranscribeStage(runner: failingRunner, services: f.services))
        await queue.enqueue(f.id)
        await queue.runUntilIdle()
        let before = try #require(try await f.job())
        #expect(before.state == .failed)
        await queue.regenerate(f.id)
        let after = try #require(try await f.job())
        #expect(after.generation == before.generation)
        #expect(after.state == .failed)
        #expect(after.completedStages == before.completedStages)
    }

    @Test func vaultUnavailableKeepsJobAndResumes() async throws {
        let f = try await setUp(createOutputFolder: false)
        let queue = f.queue(summarizer: Self.succeeding)
        await queue.enqueue(f.id)
        await queue.runUntilIdle()

        let waiting = try #require(try await f.job())
        #expect(waiting.state == .waiting)
        #expect(waiting.nextStage == StageName.writeVault)
        #expect(waiting.lastError == "output_folder_unavailable")

        try FileManager.default.createDirectory(at: f.outputFolder, withIntermediateDirectories: true)
        f.clock.advance(by: 300)
        await queue.runUntilIdle()
        #expect(f.exists(Self.titledPath))
        #expect(f.exists("_index.md"))
        #expect(try #require(try await f.job()).state == .done)
    }
}
