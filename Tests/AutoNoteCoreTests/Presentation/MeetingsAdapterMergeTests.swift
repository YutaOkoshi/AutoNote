import Testing
import Foundation
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct MeetingsAdapterMergeTests {
    actor Routed {
        var manifests: [Manifest] = []
        func add(_ m: Manifest) { manifests.append(m) }
    }

    struct Fixture {
        let paths: AppPaths
        let folder: URL
        let manifests: ManifestStore
        let output: OutputFolderServices
        let adapter: MeetingsAdapter
        let routed = Routed()

        init(queue: QueueStatus = .empty) async throws {
            let root = try TemporaryDirectory.make()
            paths = AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory))
            try paths.createBaseDirectories()
            folder = root.appending(path: "Vault", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            manifests = ManifestStore(paths: paths)
            output = OutputFolderServices(paths: paths, services: SharedVaultServices())
            _ = try await output.rebuild(outputFolder: folder.path)
            let routed = routed
            adapter = MeetingsAdapter(paths: paths, manifests: manifests, settings: SettingsStore(paths: paths), output: output,
                                      importer: AudioImporter(paths: paths, manifests: manifests),
                                      crashRecovery: CrashRecovery(paths: paths, manifests: manifests),
                                      route: { await routed.add($0) }, appVersion: "0.1.0",
                                      queueStatus: { queue }, timeZone: Samples.tokyo)
        }

        /// A finished live recording `start` seconds after `Samples.start`, with one mic file and a Vault note.
        func recording(_ suffix: String, start: Double, seconds: Double, source: MeetingSource = .live) async throws -> Manifest {
            var m = Samples.manifest
            m.id = MeetingID.make(start: Samples.start.addingTimeInterval(start), timeZone: Samples.tokyo, suffix: suffix)
            m.startedAt = Samples.start.addingTimeInterval(start)
            m.endedAt = Samples.start.addingTimeInterval(start + seconds)
            m.source = source
            var w = WAVSegmentWriter(track: .mic, meetingDirectory: paths.meetingDirectory(m.id))
            var changes = try w.open(at: .zero)
            changes += try w.write(AudioFixtures.tone(start: 0, seconds: seconds))
            changes += try w.close(at: .init(seconds: seconds))
            for case .closed(let f) in changes { m.tracks.append(f) }
            try await manifests.save(m)
            try await writeNote(m)
            return try await manifests.load(m.id)
        }

        private func writeNote(_ m: Manifest) async throws {
            try FileManager.default.createDirectory(at: paths.transcriptsDirectory(m.id), withIntermediateDirectories: true)
            let final = Transcript(utterances: [u(1, .me, "では始めます")], engine: FixtureLibrary.engine, language: .ja)
            try AutoNoteJSON.encoder().encode(final).write(to: paths.transcriptFile(m.id, .final))
            var minutes = Samples.minutes
            minutes.title = "会議 \(m.id.rawValue.suffix(4))"
            try AutoNoteJSON.encoder().encode(minutes).write(to: paths.minutesFile(m.id))
            var settings = Settings()
            settings.outputFolder = folder.path
            let context = StageContext(paths: paths, settings: settings, manifests: manifests,
                                       now: { Date(timeIntervalSince1970: 1_800_000_000) }, reportProgress: { _ in })
            var job = Job(id: m.id.rawValue, meeting: m.id, stages: StageName.all,
                          completedStages: [StageName.transcribe, StageName.summarize], state: .running, attempts: 0,
                          lastError: nil, notBefore: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            try await WriteVaultStage(timeZone: Samples.tokyo, services: SharedVaultServices()).run(&job, context: context)
            _ = try await output.vault()?.writer.rebuildIndex()
        }

        func recordingDirectories() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: paths.recordingsDirectory.path)) ?? []).sorted()
        }

        func index() throws -> String {
            try String(contentsOf: folder.appending(path: "_index.md"), encoding: .utf8)
        }
    }

    @Test func mergeCreatesAQueuedMeetingAndHidesTheSources() async throws {
        let f = try await Fixture()
        let a = try await f.recording("0001", start: 0, seconds: 2)
        let b = try await f.recording("0002", start: 3, seconds: 2)
        let c = try await f.recording("0003", start: 8, seconds: 2)
        let notes = try [a, b, c].map { try #require($0.notePath) }
        let before = try f.index()
        for note in notes {
            #expect(FileManager.default.fileExists(atPath: note))
            #expect(before.contains(URL(filePath: note).deletingPathExtension().lastPathComponent))
        }

        let newID = try await f.adapter.merge([c.id, a.id, b.id])

        // The new meeting went to the queue's entrance, ready for transcription.
        let routed = await f.routed.manifests
        #expect(routed.map(\.id) == [newID])
        #expect(routed.first?.status == .recorded)
        #expect(routed.first?.mergedFrom == [a.id, b.id, c.id])
        #expect(newID.rawValue.hasPrefix(a.id.rawValue.prefix(13)))
        #expect(try await f.manifests.load(newID).tracks.map(\.startOffset.seconds) == [0, 3, 8])
        #expect(try await f.manifests.load(newID).pauses.map(\.start.seconds) == [2, 5])

        // The sources stay on disk, linked to the new meeting, and leave the Vault and the list.
        for m in [a, b, c] {
            let loaded = try await f.manifests.load(m.id)
            #expect(loaded.mergedInto == newID)
            #expect(FileManager.default.fileExists(atPath: f.paths.meetingDirectory(m.id).appending(path: m.tracks[0].relativePath).path))
        }
        let after = try f.index()
        for note in notes {
            #expect(!FileManager.default.fileExists(atPath: note))
            #expect(!after.contains(URL(filePath: note).deletingPathExtension().lastPathComponent))
        }
        #expect(try await f.adapter.rows().map(\.id) == [newID.rawValue])
    }

    @Test func refusedMergeCreatesNothing() async throws {
        let f = try await Fixture()
        let a = try await f.recording("0001", start: 0, seconds: 2)
        let b = try await f.recording("0002", start: 3, seconds: 2, source: .imported)
        let dirs = f.recordingDirectories()

        await #expect(throws: AppCommandError.invalid(CombineError.notLive(b.id).message)) {
            try await f.adapter.merge([a.id, b.id])
        }
        #expect(f.recordingDirectories() == dirs)
        #expect(await f.routed.manifests.isEmpty)
        #expect(try await f.manifests.load(a.id) == a)
        #expect(FileManager.default.fileExists(atPath: try #require(a.notePath)))
    }

    @Test func unknownMeetingIsNotFound() async throws {
        let f = try await Fixture()
        let a = try await f.recording("0001", start: 0, seconds: 2)
        let ghost = MeetingID(rawValue: "20261024-1400-dead")
        await #expect(throws: AppCommandError.notFound("会議が見つかりません: \(ghost.rawValue)")) {
            try await f.adapter.merge([a.id, ghost])
        }
        await #expect(throws: AppCommandError.invalid(CombineError.tooFew.message)) { try await f.adapter.merge([a.id]) }
        #expect(f.recordingDirectories() == [a.id.rawValue])
    }

    @Test func aMeetingWithAnActiveJobIsRefused() async throws {
        let id = MeetingID.make(start: Samples.start.addingTimeInterval(3), timeZone: Samples.tokyo, suffix: "0002")
        let queue = QueueStatus(items: [QueueItemDTO(meetingID: id.rawValue, stage: "summarize", state: "waiting",
                                                     label: "", awaitingConfirmation: true, generation: 1)])
        let f = try await Fixture(queue: queue)
        let a = try await f.recording("0001", start: 0, seconds: 2)
        let b = try await f.recording("0002", start: 3, seconds: 2)
        #expect(b.id == id)
        await #expect(throws: AppCommandError.invalid(CombineError.processing(b.id).message)) {
            try await f.adapter.merge([a.id, b.id])
        }
        #expect(f.recordingDirectories() == [a.id.rawValue, b.id.rawValue])
    }
}
