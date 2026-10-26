import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct FinalTranscriptionRunnerTests {
    private let engine = "whisper.cpp large-v3-turbo"

    /// Writes silent WAVs under the meeting's `tracks/` folder and returns a manifest listing them.
    private func setUp(_ segments: [(track: Track, name: String, start: Double, seconds: Double)],
                       source: MeetingSource = .live) throws -> (AppPaths, Manifest) {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        var manifest = Samples.manifest
        manifest.source = source
        let tracksDir = paths.tracksDirectory(manifest.id)
        try FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        manifest.tracks = try segments.map { seg in
            try PCMAudio.writeWAV(silence(seg.seconds), to: tracksDir.appending(path: seg.name))
            return TrackFile(track: seg.track, relativePath: "tracks/\(seg.name)",
                             startOffset: TimelineTime(seconds: seg.start), durationSeconds: seg.seconds)
        }
        return (paths, manifest)
    }

    private func runner(_ fake: FakeBatchTranscriber, _ paths: AppPaths) -> FinalTranscriptionRunner {
        FinalTranscriptionRunner(transcriber: fake, engineName: engine, paths: paths, gate: BatchGate())
    }

    private func read(_ url: URL) throws -> Transcript {
        try AutoNoteJSON.decoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    @Test func offsetsAddedAndSpeakersAssigned() async throws {
        let (paths, m) = try setUp([(.mic, "mic-000.wav", 0, 2), (.system, "system-000.wav", 420, 2)])
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": [u(1.0, .unknown, "おはようございます")],
                                                  "system-0.wav": [u(1.0, .unknown, "よろしくお願いします")]])
        let r = try await runner(fake, paths)
            .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
        #expect(r.raw.utterances.map(\.start.seconds) == [1.0, 421.0])
        #expect(r.raw.utterances.map(\.speaker) == [.me, .other])
        #expect(r.raw.engine == engine)
        #expect(await fake.calls.map(\.lastPathComponent) == ["mic-0.wav", "system-0.wav"])
    }

    @Test func pauseSplitFilesKeepTheirOffsets() async throws {
        let (paths, m) = try setUp([(.mic, "mic-000.wav", 0, 2), (.mic, "mic-001.wav", 60, 2)])
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": [u(1.0, .unknown, "前半")],
                                                  "mic-1.wav": [u(1.0, .unknown, "後半")]])
        let r = try await runner(fake, paths)
            .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
        #expect(r.raw.utterances.map(\.start.seconds) == [1.0, 61.0])
        #expect(await fake.calls.map(\.lastPathComponent) == ["mic-0.wav", "mic-1.wav"])
    }

    @Test func importedMeetingIsUnknownSpeaker() async throws {
        let (paths, m) = try setUp([(.mic, "import-000.wav", 0, 2)], source: .imported)
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": [u(1.0, .unknown, "取り込みです")]])
        let r = try await runner(fake, paths)
            .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
        #expect(r.raw.utterances.map(\.speaker) == [.unknown])
        #expect(r.final.utterances.map(\.text) == ["取り込みです"])
    }

    @Test func rawKeepsFillersFinalRemovesThem() async throws {
        let (paths, m) = try setUp([(.mic, "mic-000.wav", 0, 2)])
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": [u(0.5, .unknown, "えー"), u(1.0, .unknown, "本題です")]])
        let r = try await runner(fake, paths)
            .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: true, progress: { _ in })
        #expect(r.raw.utterances.count == 2)
        #expect(r.final.utterances.map(\.text) == ["本題です"])
        #expect(r.rawURL == paths.transcriptFile(m.id, .raw))
        #expect(r.finalURL == paths.transcriptFile(m.id, .final))
        #expect(try read(r.rawURL) == r.raw)
        #expect(try read(r.finalURL) == r.final)
    }

    @Test func emptyTrackStillCompletes() async throws {
        let (paths, m) = try setUp([(.mic, "mic-000.wav", 0, 2), (.system, "system-000.wav", 0, 2)])
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": [u(1.0, .unknown, "こんにちは")], "system-0.wav": []])
        let r = try await runner(fake, paths)
            .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
        #expect(r.final.utterances.map(\.text) == ["こんにちは"])
        #expect(r.final.utterances.map(\.speaker) == [.me])
    }

    @Test func failureNamesTrackAndWritesNothing() async throws {
        let (paths, m) = try setUp([(.mic, "mic-000.wav", 0, 2), (.system, "system-000.wav", 0, 2)])
        let fake = FakeBatchTranscriber(results: [:], failure: FakeError(message: "boom"))
        await #expect {
            _ = try await runner(fake, paths)
                .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
        } throws: { error in
            guard case .trackFailed(.mic, let message)? = error as? TranscriptionError else { return false }
            return message.contains("boom")
        }
        #expect(!FileManager.default.fileExists(atPath: paths.transcriptFile(m.id, .raw).path))
        #expect(!FileManager.default.fileExists(atPath: paths.transcriptFile(m.id, .final).path))
        #expect(await fake.calls.count == 1)
    }

    @Test func noTracksIsReported() async throws {
        let (paths, m) = try setUp([])
        let fake = FakeBatchTranscriber(results: [:])
        await #expect(throws: TranscriptionError.noTracks) {
            _ = try await runner(fake, paths)
                .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
        }
    }

    @Test func progressWeightedByDuration() async throws {
        let (paths, m) = try setUp([(.mic, "mic-000.wav", 0, 1), (.system, "system-000.wav", 0, 3)])
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": [], "system-0.wav": []])
        let box = ProgressBox()
        _ = try await runner(fake, paths)
            .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { box.append($0) })
        let values = box.values
        #expect(values.contains { abs($0 - 0.25) <= 0.01 })
        #expect(values.last == 1.0)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func cancellationIsRethrownAsIs() async throws {
        let (paths, m) = try setUp([(.mic, "mic-000.wav", 0, 2)])
        let gate = BatchGate()
        await gate.pause()
        let fake = FakeBatchTranscriber(results: ["mic-0.wav": []])
        let task = Task {
            try await FinalTranscriptionRunner(transcriber: fake, engineName: engine, paths: paths, gate: gate)
                .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await fake.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.transcriptFile(m.id, .raw).path))
    }
}
