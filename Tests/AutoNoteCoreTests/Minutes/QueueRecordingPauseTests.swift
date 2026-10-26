import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

private struct PauseFixture {
    let paths: AppPaths
    let log = CallLog()
    let clock = FakeQueueClock()
    let gate = BatchGate()
    let activity = FakeRecordingActivity()
    let manifests: ManifestStore
    let jobs: JobStore

    init() throws {
        paths = AppPaths(root: try TemporaryDirectory.make())
        manifests = ManifestStore(paths: paths)
        jobs = JobStore(paths: paths)
    }

    static let id = Samples.manifest.id

    func saveManifest() async throws {
        var m = Samples.manifest
        m.status = .recorded
        try await manifests.save(m)
    }

    func queue(_ overrides: [String: ScriptedStage] = [:]) -> PostProcessingQueue {
        let stages: [any QueueStage] = [StageName.transcribe, StageName.summarize, StageName.writeVault,
                                        StageName.updateIndex].map { overrides[$0] ?? ScriptedStage(name: $0, log: log) }
        return PostProcessingQueue(paths: paths, stages: stages, activity: activity, gate: gate, clock: clock)
    }
}

private func waitFor(_ queue: PostProcessingQueue, _ condition: @Sendable (QueueSnapshot) -> Bool) async -> QueueSnapshot? {
    for await snapshot in queue.snapshots() where condition(snapshot) { return snapshot }
    return nil
}

@Suite struct QueueRecordingPauseTests {
    @Test func gateFollowsRecordingActivity() async throws {
        let f = try PauseFixture()
        let queue = f.queue()
        await queue.start()
        #expect(!f.gate.isPaused)
        f.activity.set(true)
        try await waitUntil { f.gate.isPaused }
        f.activity.set(false)
        try await waitUntil { !f.gate.isPaused }
        // Recording already in progress when the queue starts is picked up from the replayed value.
        await queue.stop()
        f.activity.set(true)
        let second = PostProcessingQueue(paths: f.paths, stages: [], activity: f.activity, gate: f.gate, clock: f.clock)
        await second.start()
        try await waitUntil { f.gate.isPaused }
        await second.stop()
    }

    @Test func transcribeIsNotStartedWhileRecording() async throws {
        let f = try PauseFixture()
        try await f.saveManifest()
        let queue = f.queue()
        await queue.start()
        f.activity.set(true)
        try await waitUntil { f.gate.isPaused }
        await queue.enqueue(PauseFixture.id)
        await queue.runUntilIdle()
        #expect(await f.log.entries.isEmpty)
        let snapshot = await queue.snapshot()
        #expect(snapshot.pausedForRecording)
        #expect(snapshot.jobs.first?.stage == StageName.transcribe)
        #expect(snapshot.jobs.first?.state == .pending)
        #expect(try await f.jobs.load(PauseFixture.id)?.state == .pending)
        f.activity.set(false)
        let done = await waitFor(queue) { $0.jobs.isEmpty }
        #expect(done?.pausedForRecording == false)
        await queue.stop()
        #expect(await f.log.entries == [StageName.transcribe, StageName.summarize, StageName.writeVault,
                                        StageName.updateIndex])
        #expect(try await f.jobs.load(PauseFixture.id)?.state == .done)
    }

    @Test func laterStagesRunWhileRecording() async throws {
        let f = try PauseFixture()
        try await f.saveManifest()
        let saved = Job(id: PauseFixture.id.rawValue, meeting: PauseFixture.id, stages: StageName.all,
                        completedStages: [StageName.transcribe], state: .pending, attempts: 0,
                        lastError: nil, notBefore: nil, createdAt: f.clock.now())
        try await f.jobs.save(saved)
        let queue = f.queue()
        await queue.start()
        f.activity.set(true)
        try await waitUntil { f.gate.isPaused }
        await queue.runUntilIdle()
        #expect(try await f.jobs.load(PauseFixture.id)?.state == .done)
        #expect(await f.log.entries == [StageName.summarize, StageName.writeVault, StageName.updateIndex])
        #expect(await queue.snapshot().pausedForRecording == false)
        await queue.stop()
    }

    @Test func runningTranscribeIsPausedNotCancelled() async throws {
        let f = try PauseFixture()
        try await f.saveManifest()
        let release = AsyncStream<Void>.makeStream()
        let transcribe = ScriptedStage(name: StageName.transcribe, log: f.log, release: release.stream)
        let queue = f.queue([StageName.transcribe: transcribe])
        await queue.start()
        await queue.enqueue(PauseFixture.id)
        let running = await waitFor(queue) { $0.jobs.first?.stage == StageName.transcribe && $0.jobs.first?.state == .running }
        #expect(running != nil)
        f.activity.set(true)
        try await waitUntil { f.gate.isPaused }
        let paused = await waitFor(queue) { $0.pausedForRecording }
        #expect(paused?.jobs.first?.state == .running)
        let held = try #require(try await f.jobs.load(PauseFixture.id))
        #expect(held.state == .running)
        #expect(held.attempts == 1)
        f.activity.set(false)
        try await waitUntil { !f.gate.isPaused }
        release.continuation.yield()
        let done = await waitFor(queue) { $0.jobs.isEmpty }
        #expect(done != nil)
        await queue.stop()
        #expect(await f.log.entries == [StageName.transcribe, StageName.summarize, StageName.writeVault,
                                        StageName.updateIndex])
        let job = try #require(try await f.jobs.load(PauseFixture.id))
        #expect(job.state == .done)
        #expect(job.attempts == 0)
    }

    @Test func sessionActivityMapsEvents() async throws {
        let id = Samples.manifest.id
        let t = TimelineTime(seconds: 1)
        let script: [RecordingEvent] = [.started(id), .paused(t), .resumed(t), .microphoneDetached(t),
                                        .stopped(Samples.manifest, .manual)]
        let activity = RecordingSessionActivity(initial: { false }, events: {
            AsyncStream { continuation in
                for event in script { continuation.yield(event) }
                continuation.finish()
            }
        })
        var values: [Bool] = []
        for await value in await activity.isRecordingUpdates() { values.append(value) }
        #expect(values == [false, true, false])
    }

    @Test func sessionActivityDoesNotRepeatInitialValue() async throws {
        let id = Samples.manifest.id
        let activity = RecordingSessionActivity(initial: { true }, events: {
            AsyncStream { continuation in
                continuation.yield(.started(id))
                continuation.yield(.stopped(Samples.manifest, .manual))
                continuation.yield(.stopped(Samples.manifest, .manual))
                continuation.finish()
            }
        })
        var values: [Bool] = []
        for await value in await activity.isRecordingUpdates() { values.append(value) }
        #expect(values == [true, false])
    }

    @Test func fakeActivityReplaysCurrentValueToEverySubscriber() async throws {
        let activity = FakeRecordingActivity()
        activity.set(true)
        var first = await activity.isRecordingUpdates().makeAsyncIterator()
        var second = await activity.isRecordingUpdates().makeAsyncIterator()
        #expect(await first.next() == true)
        #expect(await second.next() == true)
        activity.set(false)
        #expect(await first.next() == false)
        #expect(await second.next() == false)
    }
}
