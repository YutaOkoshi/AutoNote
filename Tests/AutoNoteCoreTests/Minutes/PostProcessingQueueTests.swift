import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

private actor ConcurrencyProbe {
    private(set) var current = 0
    private(set) var maximum = 0
    private(set) var order: [String] = []
    func enter(_ entry: String) { current += 1; maximum = max(maximum, current); order.append(entry) }
    func leave() { current -= 1 }
}

/// Logs `"<meeting>:<stage>"` and holds the stage open briefly so overlap would be visible.
private struct ProbeStage: QueueStage {
    let name: String
    let probe: ConcurrencyProbe
    func run(_ job: inout Job, context: StageContext) async throws {
        await probe.enter("\(job.meeting.rawValue):\(name)")
        try await Task.sleep(for: .milliseconds(5))
        await probe.leave()
    }
}

private struct Fixture {
    let paths: AppPaths
    let log = CallLog()
    let clock = FakeQueueClock()
    let manifests: ManifestStore
    let jobs: JobStore

    init() throws {
        paths = AppPaths(root: try TemporaryDirectory.make())
        manifests = ManifestStore(paths: paths)
        jobs = JobStore(paths: paths)
    }

    static let firstID = Samples.manifest.id
    static let secondID = MeetingID(rawValue: "20261024-1500-c3d4")

    func saveManifest(_ id: MeetingID = Fixture.firstID, status: MeetingStatus = .recorded) async throws {
        var m = Samples.manifest
        m.id = id
        m.status = status
        try await manifests.save(m)
    }

    func stages(_ overrides: [String: ScriptedStage] = [:]) -> [any QueueStage] {
        [StageName.transcribe, StageName.summarize, StageName.writeVault, StageName.updateIndex].map {
            overrides[$0] ?? ScriptedStage(name: $0, log: log)
        }
    }

    func queue(_ stages: [any QueueStage]) -> PostProcessingQueue {
        PostProcessingQueue(paths: paths, stages: stages, activity: NeverRecording(), gate: BatchGate(), clock: clock)
    }

    func job(_ id: MeetingID = Fixture.firstID) async throws -> Job? { try await jobs.load(id) }
}

/// First snapshot matching `condition`; records an issue and returns nil after `timeout` of real time.
private func waitFor(_ queue: PostProcessingQueue, timeout: Duration = .seconds(10),
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ condition: @escaping @Sendable (QueueSnapshot) -> Bool) async -> QueueSnapshot? {
    let found = await withTaskGroup(of: QueueSnapshot?.self) { group in
        group.addTask {
            for await snapshot in queue.snapshots() where condition(snapshot) { return snapshot }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    if found == nil { Issue.record("timed out waiting for a queue snapshot", sourceLocation: sourceLocation) }
    return found
}

@Suite struct PostProcessingQueueTests {
    @Test func enqueueCreatesPersistedJobOnlyForRecordedMeetings() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        try await f.saveManifest(Fixture.secondID, status: .recording)
        let queue = f.queue(f.stages())
        await queue.enqueue(Fixture.firstID)
        let file = f.paths.queueJobsDirectory.appending(path: "\(Fixture.firstID.rawValue).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let job = try #require(try await f.job())
        #expect(job.stages == StageName.all)
        #expect(job.state == .pending)
        #expect(job.completedStages.isEmpty)
        #expect(job.attempts == 0)
        #expect(job.createdAt == f.clock.now())

        f.clock.advance(by: 60)
        await queue.enqueue(Fixture.firstID)
        #expect(try await f.job() == job)

        await queue.enqueue(Fixture.secondID)
        #expect(try await f.job(Fixture.secondID) == nil)
        await queue.enqueue(MeetingID(rawValue: "20261024-1600-ffff"))
        #expect(try await f.jobs.all().count == 1)
        #expect(await f.log.entries.isEmpty)
    }

    @Test func runsStagesInOrderAndCompletesUnregisteredAutomations() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let queue = f.queue(f.stages())
        await queue.enqueue(Fixture.firstID)
        await queue.runUntilIdle()
        #expect(await f.log.entries == [StageName.transcribe, StageName.summarize, StageName.writeVault, StageName.updateIndex])
        let job = try #require(try await f.job())
        #expect(job.completedStages == StageName.all)
        #expect(job.state == .done)
        #expect(job.attempts == 0)
        #expect(await queue.snapshot().jobs.isEmpty)
    }

    @Test func oldestJobFirstAndOneStageAtATime() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        try await f.saveManifest(Fixture.secondID)
        let probe = ConcurrencyProbe()
        let names = [StageName.transcribe, StageName.summarize, StageName.writeVault, StageName.updateIndex]
        let queue = f.queue(names.map { ProbeStage(name: $0, probe: probe) })
        // Same createdAt under the fake clock: the tie is broken by id, whatever the enqueue order.
        await queue.enqueue(Fixture.secondID)
        await queue.enqueue(Fixture.firstID)
        let a = try #require(try await f.job(Fixture.firstID))
        let b = try #require(try await f.job(Fixture.secondID))
        #expect(a.createdAt == b.createdAt)
        await queue.runUntilIdle()
        let expected = names.map { "\(Fixture.firstID.rawValue):\($0)" } + names.map { "\(Fixture.secondID.rawValue):\($0)" }
        #expect(await probe.order == expected)
        #expect(await probe.maximum == 1)
        #expect(try await f.job(Fixture.firstID)?.state == .done)
        #expect(try await f.job(Fixture.secondID)?.state == .done)
    }

    @Test func retryWaitsUntilNotBefore() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let write = ScriptedStage(name: StageName.writeVault, log: f.log,
                                  results: [.failure(.retry(after: 300, reason: "vault_busy"))])
        let queue = f.queue(f.stages([StageName.writeVault: write]))
        await queue.enqueue(Fixture.firstID)
        let t0 = f.clock.now()
        await queue.runUntilIdle()
        var job = try #require(try await f.job())
        #expect(job.state == .waiting)
        #expect(job.notBefore == t0.addingTimeInterval(300))
        #expect(job.attempts == 1)
        #expect(job.lastError == "vault_busy")
        #expect(job.completedStages == [StageName.transcribe, StageName.summarize])

        f.clock.advance(by: 299)
        await queue.runUntilIdle()
        #expect(await f.log.entries.filter { $0 == StageName.writeVault }.count == 1)
        #expect(try await f.job()?.state == .waiting)

        f.clock.advance(by: 1)
        await queue.runUntilIdle()
        #expect(await f.log.entries.filter { $0 == StageName.writeVault }.count == 2)
        job = try #require(try await f.job())
        #expect(job.state == .done)
        #expect(job.attempts == 0)
        #expect(job.lastError == nil)
        #expect(job.notBefore == nil)
    }

    @Test func retryIsHonouredAtMostMaxAttemptsTimes() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let always = ScriptedStage(name: StageName.writeVault, log: f.log,
                                   results: Array(repeating: .failure(.retry(after: 1, reason: "busy")), count: 100))
        let queue = f.queue(f.stages([StageName.writeVault: always]))
        await queue.enqueue(Fixture.firstID)
        await queue.runUntilIdle()
        for _ in 0..<50 {
            f.clock.advance(by: 1)
            await queue.runUntilIdle()
        }
        let job = try #require(try await f.job())
        #expect(job.state == .failed)
        #expect(job.lastError == "busy")
        #expect(job.attempts == PostProcessingQueue.maxAttempts + 1)
        #expect(await f.log.entries.filter { $0 == StageName.writeVault }.count == PostProcessingQueue.maxAttempts + 1)
    }

    @Test func failedStageBlocksOnlyItsJob() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        try await f.saveManifest(Fixture.secondID)
        let write = ScriptedStage(name: StageName.writeVault, log: f.log, results: [.failure(.failed(reason: "no_vault"))])
        let queue = f.queue(f.stages([StageName.writeVault: write]))
        await queue.enqueue(Fixture.firstID)
        f.clock.advance(by: 1)
        await queue.enqueue(Fixture.secondID)
        await queue.runUntilIdle()
        var old = try #require(try await f.job(Fixture.firstID))
        #expect(old.state == .failed)
        #expect(old.lastError == "no_vault")
        #expect(old.completedStages == [StageName.transcribe, StageName.summarize])
        #expect(try await f.job(Fixture.secondID)?.state == .done)
        let failed = await queue.snapshot().jobs.first { $0.meetingID == Fixture.firstID }
        #expect(failed?.state == .failed)
        #expect(failed?.stage == StageName.writeVault)
        #expect(failed?.lastError == "no_vault")

        await queue.retry(Fixture.firstID)
        await queue.runUntilIdle()
        old = try #require(try await f.job(Fixture.firstID))
        #expect(old.state == .done)
        #expect(old.completedStages == StageName.all)
        #expect(old.generation == 0)
        // retry of an unknown or finished job is a logged no-op
        await queue.retry(MeetingID(rawValue: "nope"))
        await queue.retry(Fixture.firstID)
        #expect(try await f.job(Fixture.firstID) == old)
    }

    @Test func awaitingConfirmationResolves() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        try await f.saveManifest(Fixture.secondID)
        let approved = Approvals()
        let write = ScriptedStage(name: StageName.writeVault, log: f.log,
                                  results: [.failure(.awaitingConfirmation(path: "2026/x.md")),
                                            .failure(.awaitingConfirmation(path: "2026/x.md"))],
                                  onRun: { job in approved.record(job.meeting, job.overwriteApproved) })
        let queue = f.queue(f.stages([StageName.writeVault: write]))
        await queue.enqueue(Fixture.firstID)
        f.clock.advance(by: 1)
        await queue.enqueue(Fixture.secondID)
        await queue.runUntilIdle()
        for id in [Fixture.firstID, Fixture.secondID] {
            let job = try #require(try await f.job(id))
            #expect(job.state == .waiting)
            #expect(job.notBefore == nil)
            #expect(job.lastError == "overwrite_confirmation: 2026/x.md")
        }
        let snapshot = await queue.snapshot()
        #expect(snapshot.jobs.map(\.awaitingConfirmation) == [true, true])
        #expect(snapshot.jobs.map(\.meetingID) == [Fixture.firstID, Fixture.secondID])

        try await queue.resolveOverwrite(Fixture.firstID, overwrite: true)
        await queue.runUntilIdle()
        let first = try #require(try await f.job(Fixture.firstID))
        #expect(first.overwriteApproved)
        #expect(first.state == .done)
        #expect(approved.values(Fixture.firstID) == [false, true])

        try await queue.resolveOverwrite(Fixture.secondID, overwrite: false)
        let second = try #require(try await f.job(Fixture.secondID))
        #expect(second.state == .done)
        #expect(second.completedStages.contains(StageName.writeVault))
        #expect(second.completedStages.contains(StageName.updateIndex))
        #expect(second.completedStages.contains(StageName.automations))
        #expect(try await f.manifests.load(Fixture.secondID).status == .minutesGenerated)
        #expect(approved.values(Fixture.secondID) == [false])
        // a missing job is a logged no-op
        try await queue.resolveOverwrite(MeetingID(rawValue: "nope"), overwrite: true)
        #expect(try await f.job(MeetingID(rawValue: "nope")) == nil)
    }

    @Test func resolveOverwriteIgnoresJobsNotAwaitingConfirmation() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let release = AsyncStream<Void>.makeStream()
        let summarize = ScriptedStage(name: StageName.summarize, log: f.log, release: release.stream)
        let queue = f.queue(f.stages([StageName.summarize: summarize]))
        await queue.enqueue(Fixture.firstID)
        let manifestBefore = try await f.manifests.load(Fixture.firstID)

        // .pending
        let pending = try #require(try await f.job())
        try await queue.resolveOverwrite(Fixture.firstID, overwrite: false)
        try await queue.resolveOverwrite(Fixture.firstID, overwrite: true)
        #expect(try await f.job() == pending)

        // .running (summarize held open)
        await queue.start()
        _ = await waitFor(queue) { $0.jobs.first?.stage == StageName.summarize && $0.jobs.first?.state == .running }
        let running = try #require(try await f.job())
        #expect(running.state == .running)
        try await queue.resolveOverwrite(Fixture.firstID, overwrite: false)
        try await queue.resolveOverwrite(Fixture.firstID, overwrite: true)
        #expect(try await f.job() == running)
        #expect(try await f.manifests.load(Fixture.firstID) == manifestBefore)

        release.continuation.yield()
        _ = await waitFor(queue) { $0.jobs.isEmpty }
        await queue.stop()
        let done = try #require(try await f.job())
        #expect(done.state == .done)
        #expect(done.overwriteApproved == false)
        #expect(try await f.manifests.load(Fixture.firstID) == manifestBefore)
    }

    @Test func rerunWhileStageRunsResetsAndBumpsGeneration() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let release = AsyncStream<Void>.makeStream()
        let write = ScriptedStage(name: StageName.writeVault, log: f.log, release: release.stream)
        let queue = f.queue(f.stages([StageName.writeVault: write]))
        await queue.start()
        await queue.enqueue(Fixture.firstID)
        _ = await waitFor(queue) { $0.jobs.first?.stage == StageName.writeVault && $0.jobs.first?.state == .running }
        try await queue.rerun(Fixture.firstID, from: StageName.summarize)
        let reset = try #require(try await f.job())
        #expect(reset.generation == 1)
        #expect(reset.completedStages == [StageName.transcribe])
        #expect(reset.state == .pending)
        #expect(reset.attempts == 0)

        // The loop picks the job up again: summarize, then write_vault (held once more).
        _ = await waitFor(queue) { $0.jobs.first?.stage == StageName.writeVault && $0.jobs.first?.state == .running }
        release.continuation.yield()
        _ = await waitFor(queue) { $0.jobs.isEmpty }
        await queue.stop()
        let job = try #require(try await f.job())
        #expect(job.state == .done)
        #expect(job.generation == 1)
        #expect(job.completedStages == StageName.all)
        #expect(await f.log.entries == [StageName.transcribe, StageName.summarize, StageName.writeVault,
                                        StageName.summarize, StageName.writeVault, StageName.updateIndex])
    }

    @Test func rateLimitedJobRerunsSummarizeWithNewGeneration() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let first = FirstTime()
        let summarize = ScriptedStage(name: StageName.summarize, log: f.log, onRun: { job in
            if first.take() { job.summaryFailure = "rate_limited: x" }
        })
        let queue = f.queue(f.stages([StageName.summarize: summarize]))
        await queue.enqueue(Fixture.firstID)
        let t0 = f.clock.now()
        await queue.runUntilIdle()
        var job = try #require(try await f.job())
        #expect(job.completedStages == StageName.all)
        #expect(job.state == .waiting)
        #expect(job.notBefore == t0.addingTimeInterval(3600))
        let waiting = await queue.snapshot().jobs.first
        #expect(waiting?.summaryFailure == .rateLimited)
        #expect(waiting?.awaitingConfirmation == false)

        f.clock.advance(by: 3599)
        await queue.runUntilIdle()
        #expect(await f.log.entries.count == 4)

        f.clock.advance(by: 1)
        await queue.runUntilIdle()
        #expect(await f.log.entries == [StageName.transcribe, StageName.summarize, StageName.writeVault, StageName.updateIndex,
                                        StageName.summarize, StageName.writeVault, StageName.updateIndex])
        job = try #require(try await f.job())
        #expect(job.generation == 1)
        #expect(job.state == .done)
        #expect(job.summaryFailure == nil)
    }

    @Test func rateLimitRoundsStopAfterMaxAttempts() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let summarize = ScriptedStage(name: StageName.summarize, log: f.log, onRun: { job in
            job.summaryFailure = "rate_limited: x"
        })
        let queue = f.queue(f.stages([StageName.summarize: summarize]))
        await queue.enqueue(Fixture.firstID)
        await queue.runUntilIdle()
        for _ in 0..<40 {
            f.clock.advance(by: 3600)
            await queue.runUntilIdle()
        }
        let job = try #require(try await f.job())
        #expect(job.state == .failed)
        #expect(job.lastError == "rate_limited: x")
        #expect(await f.log.entries.filter { $0 == StageName.summarize }.count == PostProcessingQueue.maxAttempts + 1)
        // a failed job with a summary failure stays visible
        #expect(await queue.snapshot().jobs.first?.summaryFailure == .rateLimited)
    }

    @Test func restartResumesInterruptedStageWithoutCountingAttempt() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let interrupted = Job(id: Fixture.firstID.rawValue, meeting: Fixture.firstID, stages: StageName.all,
                              completedStages: [StageName.transcribe], state: .running, attempts: 3,
                              lastError: nil, notBefore: nil, createdAt: f.clock.now())
        try await f.jobs.save(interrupted)
        let release = AsyncStream<Void>.makeStream()
        let summarize = ScriptedStage(name: StageName.summarize, log: f.log, release: release.stream)
        let queue = f.queue(f.stages([StageName.summarize: summarize]))
        await queue.start()
        // Recovery gives back the interrupted attempt (3 -> 2); re-running summarize counts it again (-> 3).
        // Counting the recovery as an attempt would show 4.
        let running = await waitFor(queue) { $0.jobs.first?.stage == StageName.summarize && $0.jobs.first?.state == .running }
        #expect(running != nil)
        #expect(try await f.job()?.attempts == interrupted.attempts)
        release.continuation.yield()
        let done = await waitFor(queue) { $0.jobs.isEmpty }
        #expect(done != nil)
        await queue.stop()
        #expect(await f.log.entries == [StageName.summarize, StageName.writeVault, StageName.updateIndex])
        let job = try #require(try await f.job())
        #expect(job.state == .done)
        #expect(job.attempts == 0)
    }

    @Test func startResetsRunningJobAndUsesSavedStages() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        try await f.saveManifest(Fixture.secondID)
        let interrupted = Job(id: Fixture.firstID.rawValue, meeting: Fixture.firstID, stages: StageName.all,
                              completedStages: [StageName.transcribe], state: .running, attempts: 1,
                              lastError: nil, notBefore: nil, createdAt: f.clock.now())
        try await f.jobs.save(interrupted)
        let odd = Job(id: Fixture.secondID.rawValue, meeting: Fixture.secondID, stages: [StageName.transcribe, "bogus"],
                      completedStages: [], state: .pending, attempts: 0, lastError: nil, notBefore: nil,
                      createdAt: f.clock.now().addingTimeInterval(1))
        try await f.jobs.save(odd)
        let queue = f.queue(f.stages())
        await queue.start()
        await queue.stop()
        // stop() never leaves a job .running on disk
        for id in [Fixture.firstID, Fixture.secondID] { #expect(try await f.job(id)?.state != .running) }
        await queue.runUntilIdle()
        #expect(try await f.job()?.state == .done)
        let failed = try #require(try await f.job(Fixture.secondID))
        #expect(failed.state == .failed)
        #expect(failed.lastError == "unknown_stage: bogus")
        #expect(failed.completedStages == [StageName.transcribe])
    }

    @Test func stopCancelsRunningStageBackToPending() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let release = AsyncStream<Void>.makeStream()
        let summarize = ScriptedStage(name: StageName.summarize, log: f.log, release: release.stream)
        let queue = f.queue(f.stages([StageName.summarize: summarize]))
        await queue.start()
        await queue.enqueue(Fixture.firstID)
        let running = await waitFor(queue) { $0.jobs.first?.stage == StageName.summarize && $0.jobs.first?.state == .running }
        #expect(running != nil)
        await queue.stop()
        let job = try #require(try await f.job())
        #expect(job.state == .pending)
        #expect(job.attempts == 0)
        #expect(job.completedStages == [StageName.transcribe])
    }

    @Test func startLoopWakesAtNotBefore() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let write = ScriptedStage(name: StageName.writeVault, log: f.log,
                                  results: [.failure(.retry(after: 300, reason: "busy"))])
        let queue = f.queue(f.stages([StageName.writeVault: write]))
        await queue.start()
        await queue.enqueue(Fixture.firstID)
        let waiting = await waitFor(queue) { $0.jobs.first?.state == .waiting }
        #expect(waiting?.jobs.first?.notBefore == f.clock.now().addingTimeInterval(300))
        f.clock.advance(by: 300)
        let done = await waitFor(queue) { $0.jobs.isEmpty }
        #expect(done != nil)
        await queue.stop()
        #expect(try await f.job()?.state == .done)
    }

    @Test func rerunFromSummarizeResetsDownstreamAndBumpsGeneration() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let queue = f.queue(f.stages())
        await queue.enqueue(Fixture.firstID)
        await queue.runUntilIdle()
        try await queue.rerun(Fixture.firstID, from: StageName.summarize)
        var job = try #require(try await f.job())
        #expect(job.completedStages == [StageName.transcribe])
        #expect(job.generation == 1)
        #expect(job.state == .pending)
        #expect(job.attempts == 0)
        #expect(job.overwriteApproved == false)
        await queue.runUntilIdle()
        #expect(try await f.job()?.state == .done)

        try await queue.rerun(Fixture.firstID, from: StageName.writeVault)
        job = try #require(try await f.job())
        #expect(job.completedStages == [StageName.transcribe, StageName.summarize])
        #expect(job.generation == 1)

        await #expect(throws: QueueError.unknownStage("nope")) {
            try await queue.rerun(Fixture.firstID, from: "nope")
        }
        await #expect(throws: QueueError.unknownMeeting(Fixture.secondID)) {
            try await queue.rerun(Fixture.secondID, from: StageName.summarize)
        }
    }

    @Test func snapshotsReportProgress() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        let release = AsyncStream<Void>.makeStream()
        let transcribe = ScriptedStage(name: StageName.transcribe, log: f.log, progress: 0.5, release: release.stream)
        let queue = f.queue(f.stages([StageName.transcribe: transcribe]))
        await queue.start()
        await queue.enqueue(Fixture.firstID)
        let seen = await waitFor(queue) { $0.jobs.first?.progress == 0.5 }
        #expect(seen?.jobs.first?.stage == StageName.transcribe)
        #expect(seen?.jobs.first?.state == .running)
        #expect(seen?.pausedForRecording == false)
        release.continuation.yield()
        let done = await waitFor(queue) { $0.jobs.isEmpty }
        #expect(done != nil)
        await queue.stop()
        let saved = try String(contentsOf: f.paths.queueJobsDirectory.appending(path: "\(Fixture.firstID.rawValue).json"),
                               encoding: .utf8)
        #expect(!saved.contains("progress"))
    }

    @Test func unexpectedErrorMarksFailedWithShortMessage() async throws {
        let f = try Fixture()
        try await f.saveManifest()
        var stages = f.stages()
        stages[1] = FakeQueueStage(name: StageName.summarize, log: f.log,
                                   failure: FakeError(message: String(repeating: "e", count: 1_000)))
        let queue = f.queue(stages)
        await queue.enqueue(Fixture.firstID)
        await queue.runUntilIdle()
        let job = try #require(try await f.job())
        #expect(job.state == .failed)
        #expect(job.lastError?.count == 300)
        #expect(job.completedStages == [StageName.transcribe])
        #expect(await f.log.entries == [StageName.transcribe, StageName.summarize])
    }
}

/// Records `overwriteApproved` seen per meeting by a stage's `onRun`.
private final class Approvals: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [MeetingID: [Bool]] = [:]
    func record(_ id: MeetingID, _ value: Bool) { lock.withLock { seen[id, default: []].append(value) } }
    func values(_ id: MeetingID) -> [Bool] { lock.withLock { seen[id] ?? [] } }
}

private final class FirstTime: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
}
