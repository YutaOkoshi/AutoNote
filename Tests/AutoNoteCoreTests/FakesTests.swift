import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Test func fakesFollowProtocols() async throws {
    let live: any LiveTranscriber = FakeLiveTranscriber(script: [u(1, .me, "a")])
    let stream = try await live.start(language: .ja, hints: ["ルミナ茶"])
    await live.feed(AudioChunk(track: .mic, samples: [0, 0], start: .zero, hostTime: 0)); await live.finish()
    var got: [String] = []; for await x in stream { got.append(x.text) }
    #expect(got == ["a"])
    let batch: any BatchTranscriber = FakeBatchTranscriber(results: ["mic-000.wav": [u(2, .me, "b")]])
    #expect(try await batch.transcribe(file: URL(filePath: "/x/mic-000.wav"), language: .ja, hints: []) { _ in }.map(\.text) == ["b"])
    let s = FakeSummarizer(result: .success(Samples.minutes))
    let input = SummaryInput(instructions: "x", terms: [], bookmarks: [], transcript: Transcript(utterances: [], engine: "e", language: .ja), language: .ja)
    #expect(try await s.summarize(input) == Samples.minutes); #expect(await s.inputs == [input])
}
@Test func fakeStageRunsAndJobRoundTrips() async throws {
    let log = CallLog(); let stage: any QueueStage = FakeQueueStage(name: StageName.summarize, log: log, failure: nil)
    var job = Job(id: "j1", meeting: Samples.manifest.id, stages: StageName.all, completedStages: ["transcribe"], state: .pending, attempts: 0, lastError: nil, notBefore: nil, createdAt: Samples.start)
    #expect(job.nextStage == "summarize"); #expect(job.generation == 0); #expect(job.overwriteApproved == false)
    job.generation = 1; job.transcriptEngine = "whisper.cpp large-v3-turbo"; job.summaryFailure = "rate_limit"
    let paths = AppPaths(root: try TemporaryDirectory.make())
    try await stage.run(&job, context: StageContext(paths: paths, settings: Settings(), manifests: ManifestStore(paths: paths), now: { Samples.start }, reportProgress: { _ in }))
    #expect(await log.entries == ["summarize"])
    #expect(try AutoNoteJSON.decoder().decode(Job.self, from: AutoNoteJSON.encoder().encode(job)) == job)
}
@Test func jobDecodesWithMissingTailFieldsAndStageNamesAreOrdered() throws {
    let json = #"{"id":"j","meeting":"20261024-1400-a1b2","stages":["transcribe"],"completed_stages":["transcribe"],"state":"done","attempts":1,"created_at":"2026-10-24T05:00:00Z"}"#
    let job = try AutoNoteJSON.decoder().decode(Job.self, from: Data(json.utf8))
    #expect(job.generation == 0 && job.transcriptEngine == nil && job.summaryFailure == nil && job.overwriteApproved == false && job.nextStage == nil)
    #expect(StageName.all == ["transcribe", "summarize", "write_vault", "update_index", "automations"])
    #expect(AudioChunk(track: .mic, samples: [Int16](repeating: 0, count: 8000), start: .zero, hostTime: 0).duration == 0.5)
}
@Test func fakeStageAndBatchFailures() async throws {
    let log = CallLog(); let stage = FakeQueueStage(name: "x", log: log, failure: FakeError(message: "boom"))
    var job = Job(id: "j", meeting: Samples.manifest.id, stages: ["x"], completedStages: [], state: .pending, attempts: 0, lastError: nil, notBefore: nil, createdAt: Samples.start)
    let paths = AppPaths(root: try TemporaryDirectory.make())
    await #expect(throws: FakeError(message: "boom")) {
        try await stage.run(&job, context: StageContext(paths: paths, settings: Settings(), manifests: ManifestStore(paths: paths), now: { Samples.start }, reportProgress: { _ in }))
    }
    #expect(await log.entries == ["x"])
    let batch = FakeBatchTranscriber(results: [:], failure: FakeError(message: "nope"))
    await #expect(throws: FakeError(message: "nope")) { try await batch.transcribe(file: URL(filePath: "/a.wav"), language: .en, hints: []) { _ in } }
    #expect(await batch.calls == [URL(filePath: "/a.wav")])
}
