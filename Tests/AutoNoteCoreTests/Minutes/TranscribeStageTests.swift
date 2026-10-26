import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Synchronization
import Testing

@Suite struct TranscribeStageTests {
    private let engine = "whisper.cpp large-v3-turbo"

    private struct Fixture {
        let paths: AppPaths
        let manifests: ManifestStore
        let manifest: Manifest
        let outputFolder: URL
    }

    /// A `.recorded` meeting with one silent mic track, plus an empty output folder.
    private func setUp() async throws -> Fixture {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        var manifest = Samples.manifest
        manifest.status = .recorded
        let tracksDir = paths.tracksDirectory(manifest.id)
        try FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try PCMAudio.writeWAV(Array(repeating: 0, count: 16_000), to: tracksDir.appending(path: "mic-000.wav"))
        manifest.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav",
                                     startOffset: TimelineTime(seconds: 0), durationSeconds: 1)]
        let manifests = ManifestStore(paths: paths)
        try await manifests.save(manifest)
        let outputFolder = try TemporaryDirectory.make()
        return Fixture(paths: paths, manifests: manifests, manifest: manifest, outputFolder: outputFolder)
    }

    private func stage(_ fake: FakeBatchTranscriber, _ f: Fixture) -> TranscribeStage {
        TranscribeStage(runner: FinalTranscriptionRunner(transcriber: fake, engineName: engine,
                                                         paths: f.paths, gate: BatchGate()),
                        services: SharedVaultServices())
    }

    private func context(_ f: Fixture, progress: @escaping @Sendable (Double) -> Void = { _ in }) -> StageContext {
        var settings = Settings()
        settings.outputFolder = f.outputFolder.path
        settings.fillerRemoval = true
        return StageContext(paths: f.paths, settings: settings, manifests: f.manifests,
                            now: { Date(timeIntervalSince1970: 1_800_000_000) }, reportProgress: progress)
    }

    private func job(_ f: Fixture) -> Job {
        Job(id: f.manifest.id.rawValue, meeting: f.manifest.id, stages: StageName.all, completedStages: [],
            state: .running, attempts: 0, lastError: nil, notBefore: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func read(_ url: URL) throws -> Transcript {
        try AutoNoteJSON.decoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    private func writeLive(_ f: Fixture, _ utterances: [Utterance]) throws {
        let url = f.paths.transcriptFile(f.manifest.id, .live)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let live = Transcript(utterances: utterances, engine: "DictationTranscriber", language: f.manifest.language)
        try AutoNoteJSON.encoder().encode(live).write(to: url)
    }

    @Test func nameIsTranscribe() async throws {
        let f = try await setUp()
        #expect(stage(FakeBatchTranscriber(results: [:]), f).name == "transcribe")
    }

    @Test func successRecordsEngineAndStatus() async throws {
        let f = try await setUp()
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": [u(1, .unknown, "はじめます")]])
        let seen = Mutex<[MeetingStatus]>([])
        let manifestURL = f.paths.manifestFile(f.manifest.id)
        let ctx = context(f) { _ in
            if let m = try? AutoNoteJSON.decoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) {
                seen.withLock { $0.append(m.status) }
            }
        }
        var j = job(f)
        try await stage(fake, f).run(&j, context: ctx)
        #expect(j.transcriptEngine == engine)
        #expect(try await f.manifests.load(f.manifest.id).status == .transcribed)
        #expect(seen.withLock { $0 }.contains(.transcribing))
        let final = try read(f.paths.transcriptFile(f.manifest.id, .final))
        #expect(final.utterances.map(\.text) == ["はじめます"])
        #expect(final.engine == engine)
    }

    @Test func fallsBackToLiveTranscript() async throws {
        let f = try await setUp()
        try writeLive(f, [u(1, .me, "えーと、オートノートです")])
        let dictDir = f.outputFolder.appending(path: "_autonote", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)
        let dictionary = DictionaryFile(terms: [], replacements: [Replacement(from: "オートノート", to: "AutoNote")],
                                        fillers: DictionaryFile.defaultFillers)
        try Data(dictionary.render().utf8).write(to: dictDir.appending(path: "dictionary.md"))
        let fake = FakeBatchTranscriber(results: [:], failure: FakeError(message: "x"))

        var j = job(f)
        try await stage(fake, f).run(&j, context: context(f))
        let label = "DictationTranscriber（確定版の失敗によりリアルタイム版で代用）"
        #expect(j.transcriptEngine == label)
        #expect(try await f.manifests.load(f.manifest.id).status == .transcribed)
        let raw = try read(f.paths.transcriptFile(f.manifest.id, .raw))
        #expect(raw.utterances.map(\.text) == ["えーと、オートノートです"])
        #expect(raw.engine == label)
        let final = try read(f.paths.transcriptFile(f.manifest.id, .final))
        let text = final.utterances.map(\.text).joined()
        #expect(text.contains("AutoNote"))
        #expect(!text.contains("オートノート"))
        #expect(!text.contains("えーと"))
        #expect(final.engine == label)
    }

    @Test func failsWithoutLiveTranscript() async throws {
        let f = try await setUp()
        let fake = FakeBatchTranscriber(results: [:], failure: FakeError(message: "x"))
        var j = job(f)
        await #expect(throws: StageError.self) { try await stage(fake, f).run(&j, context: context(f)) }
        #expect(try await f.manifests.load(f.manifest.id).status == .failed)
        #expect(j.transcriptEngine == nil)
    }

    @Test func emptyLiveTranscriptIsNotUsed() async throws {
        let f = try await setUp()
        try writeLive(f, [])
        let fake = FakeBatchTranscriber(results: [:], failure: FakeError(message: "x"))
        var j = job(f)
        do {
            try await stage(fake, f).run(&j, context: context(f))
            Issue.record("expected StageError.failed")
        } catch let error as StageError {
            guard case .failed = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(try await f.manifests.load(f.manifest.id).status == .failed)
        #expect(!FileManager.default.fileExists(atPath: f.paths.transcriptFile(f.manifest.id, .final).path))
    }
}
