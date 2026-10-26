import Testing
import Foundation
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct QueueAdapterTests {
    struct Fixture {
        let paths: AppPaths
        let manifests: ManifestStore
        let log = CallLog()
        let id = Samples.manifest.id

        init() async throws {
            paths = AppPaths(root: try TemporaryDirectory.make())
            try paths.createBaseDirectories()
            manifests = ManifestStore(paths: paths)
            var m = Samples.manifest
            m.status = .recorded
            try await manifests.save(m)
        }

        func queue(transcribeFails: Bool = false, summaryFailure: String? = nil) -> PostProcessingQueue {
            let transcribe: any QueueStage = transcribeFails
                ? FakeQueueStage(name: StageName.transcribe, log: log, failure: FakeError(message: "whisper"))
                : FakeQueueStage(name: StageName.transcribe, log: log, failure: nil)
            let summarize = ScriptedStage(name: StageName.summarize, log: log, onRun: { job in
                if let summaryFailure { job.summaryFailure = summaryFailure }
            })
            let rest = [StageName.writeVault, StageName.updateIndex].map { FakeQueueStage(name: $0, log: log, failure: nil) }
            return PostProcessingQueue(paths: paths, stages: [transcribe, summarize] + rest, activity: NeverRecording(),
                                       gate: BatchGate(), clock: FakeQueueClock())
        }

        func writeFinal() throws {
            try FileManager.default.createDirectory(at: paths.transcriptsDirectory(id), withIntermediateDirectories: true)
            let final = Transcript(utterances: [u(1, .me, "テスト")], engine: "fake", language: .ja)
            try AutoNoteJSON.encoder().encode(final).write(to: paths.transcriptFile(id, .final))
        }

        func count(_ stage: String) async -> Int { await log.entries.filter { $0 == stage }.count }
    }

    @Test func retryFailedUsesQueueRetry() async throws {
        // A job whose transcribe failed: retry re-runs that same stage, generation unchanged.
        let f = try await Fixture()
        let queue = f.queue(transcribeFails: true)
        let adapter = QueueAdapter(holder: QueueHolder(queue))
        await queue.enqueue(f.id)
        await queue.runUntilIdle()
        let failed = try #require(await adapter.status().items.first)
        #expect(failed.state == "failed" && failed.stage == StageName.transcribe && failed.generation == 0)
        try await adapter.retry(f.id)
        await queue.runUntilIdle()
        #expect(await f.count(StageName.transcribe) == 2)
        #expect(await f.count(StageName.summarize) == 0)
        #expect(await adapter.status().items.first?.generation == 0)

        // A job that finished with a summaryFailure: retry becomes regenerate, generation + 1.
        let g = try await Fixture()
        try g.writeFinal()
        let queue2 = g.queue(summaryFailure: "not_logged_in: login")
        let adapter2 = QueueAdapter(holder: QueueHolder(queue2))
        await queue2.enqueue(g.id)
        await queue2.runUntilIdle()
        let done = try #require(await adapter2.status().items.first)
        #expect(done.state == "done" && done.summaryFailure == "not_logged_in" && done.generation == 0)
        try await adapter2.retry(g.id)
        await queue2.runUntilIdle()
        #expect(await g.count(StageName.transcribe) == 1)
        #expect(await g.count(StageName.summarize) == 2)
        #expect(await adapter2.status().items.first?.generation == 1)
    }

    /// X13: pre-validation copy.
    @Test func preValidationErrors() async throws {
        let f = try await Fixture()
        let queue = f.queue()
        let adapter = QueueAdapter(holder: QueueHolder(queue))
        let unknown = MeetingID(rawValue: "20261024-1500-ffff")
        await #expect(throws: AppCommandError.notFound("会議が見つかりません: 20261024-1500-ffff")) { try await adapter.retry(unknown) }
        await #expect(throws: AppCommandError.notFound("会議が見つかりません: 20261024-1500-ffff")) { try await adapter.delete(unknown) }
        await #expect(throws: AppCommandError.invalid("文字起こしがありません: \(f.id.rawValue)")) { try await adapter.regenerate(f.id) }
        await #expect(throws: AppCommandError.invalid("短すぎる録音ではありません: \(f.id.rawValue)")) {
            try await adapter.acceptShortRecording(f.id)
        }
    }

    /// X14b: without a job, a finished meeting regenerates (generation + 1, from summarize).
    @Test func retryWithoutJobRegeneratesFinishedMeeting() async throws {
        let f = try await Fixture()
        _ = try await f.manifests.update(f.id) { $0.status = .transcriptOnly }
        try f.writeFinal()
        // The summarize stage keeps a summaryFailure so the finished job stays visible with its generation.
        let queue = f.queue(summaryFailure: "not_logged_in: login")
        let adapter = QueueAdapter(holder: QueueHolder(queue))
        #expect(await adapter.status().items.isEmpty)
        try await adapter.retry(f.id)
        await queue.runUntilIdle()
        #expect(await f.count(StageName.transcribe) == 0)
        #expect(await f.count(StageName.summarize) == 1)
        #expect(await adapter.status().items.first?.generation == 1)
    }

    /// X14b: without a job, in-flight and too-short meetings are refused; a finished one needs final.json.
    @Test func retryWithoutJobRefusals() async throws {
        let f = try await Fixture()
        let adapter = QueueAdapter(holder: QueueHolder(f.queue()))
        let id = f.id.rawValue
        for status in [MeetingStatus.recorded, .transcribing, .transcribed, .generating] {
            _ = try await f.manifests.update(f.id) { $0.status = status }
            await #expect(throws: AppCommandError.invalid("処理中です: \(id)")) { try await adapter.retry(f.id) }
        }
        _ = try await f.manifests.update(f.id) { $0.status = .tooShort }
        await #expect(throws: AppCommandError.invalid("短すぎる録音です: \(id)")) { try await adapter.retry(f.id) }
        _ = try await f.manifests.update(f.id) { $0.status = .minutesGenerated }
        await #expect(throws: AppCommandError.invalid("文字起こしがありません: \(id)")) { try await adapter.retry(f.id) }
    }

    /// X14b: a pending job is refused as in progress.
    @Test func retryPendingJobIsInProgress() async throws {
        let f = try await Fixture()
        let queue = f.queue()
        let adapter = QueueAdapter(holder: QueueHolder(queue))
        await queue.enqueue(f.id)
        #expect(await adapter.status().items.first?.state == "pending")
        await #expect(throws: AppCommandError.invalid("処理中です: \(f.id.rawValue)")) { try await adapter.retry(f.id) }
    }
}
