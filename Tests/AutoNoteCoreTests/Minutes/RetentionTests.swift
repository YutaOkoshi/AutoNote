import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

private let day: TimeInterval = 86_400

private struct RetentionFixture {
    let paths: AppPaths
    let manifests: ManifestStore
    let jobs: JobStore
    let now = Samples.start

    init() throws {
        paths = AppPaths(root: try TemporaryDirectory.make())
        manifests = ManifestStore(paths: paths)
        jobs = JobStore(paths: paths)
    }

    /// A meeting that ended `daysAgo` days before `now`, with `tracks/` and `merged/` audio and (optionally) `final.json`.
    @discardableResult
    func meeting(_ id: String, daysAgo: Double, status: MeetingStatus = .minutesGenerated,
                 finalTranscript: Bool = true, completed: [String]? = [StageName.transcribe]) async throws -> MeetingID {
        let meeting = MeetingID(rawValue: id)
        var m = Samples.manifest
        m.id = meeting
        m.status = status
        m.endedAt = now.addingTimeInterval(-daysAgo * day)
        m.startedAt = m.endedAt!.addingTimeInterval(-3600)
        try await manifests.save(m)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.tracksDirectory(meeting), withIntermediateDirectories: true)
        try Data("fake-pcm".utf8).write(to: paths.tracksDirectory(meeting).appending(path: "me-001.caf"))
        try fm.createDirectory(at: merged(meeting), withIntermediateDirectories: true)
        try Data("fake-pcm".utf8).write(to: merged(meeting).appending(path: "mixed.m4a"))
        if finalTranscript {
            let url = paths.transcriptFile(meeting, .final)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AutoNoteJSON.encoder().encode(Transcript(utterances: [u(1, .me, "はじめます")], engine: "e", language: .ja))
                .write(to: url)
        }
        if let completed {
            try await jobs.save(Job(id: id, meeting: meeting, stages: StageName.all, completedStages: completed,
                                    state: completed.count == StageName.all.count ? .done : .pending, attempts: 0,
                                    lastError: nil, notBefore: nil, createdAt: now))
        }
        return meeting
    }

    func merged(_ id: MeetingID) -> URL { paths.meetingDirectory(id).appending(path: "merged", directoryHint: .isDirectory) }

    func hasAudio(_ id: MeetingID) -> Bool {
        let fm = FileManager.default
        let tracks = fm.fileExists(atPath: paths.tracksDirectory(id).path)
        let merged = fm.fileExists(atPath: merged(id).path)
        #expect(tracks == merged, "tracks/ and merged/ should go together for \(id.rawValue)")
        return tracks && merged
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A Vault document written for `id`, then renamed by the user; returns the output folder and the renamed file.
    /// With `services`, the document goes through that instance's shared writer, as a queue stage's would.
    func writeToVault(_ id: MeetingID, services: SharedVaultServices? = nil) async throws -> (folder: URL, file: URL) {
        let folder = try TemporaryDirectory.make()
        var m = try await manifests.load(id)
        m.status = .minutesGenerated
        let doc = MeetingDocument(manifest: m, transcript: Transcript(utterances: [u(5, .me, "a")], engine: "e", language: .ja),
                                  minutes: Samples.minutes, frontmatter: .init(text: FrontmatterTemplate.defaultText),
                                  appVersion: "0.1.0", timeZone: Samples.tokyo)
        let writer = services?.vaultWriter(outputFolder: folder, paths: paths, now: { Date() })
            ?? VaultWriter(outputFolder: folder, paths: paths)
        guard case .written(let file) = try await writer.write(doc) else { throw FakeError(message: "not written") }
        _ = try await writer.rebuildIndex()
        let renamed = file.deletingLastPathComponent().appending(path: "利用者が改名した定例.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        return (folder, renamed)
    }
}

/// Polls `condition` (real time) until it holds; records an issue on timeout.
private func eventually(timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
                        _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met in time", sourceLocation: sourceLocation)
}

@Suite struct RetentionTests {
    @Test func purgesAudioOlderThanRetention() async throws {
        let f = try RetentionFixture()
        let old = try await f.meeting("20260923-1400-0001", daysAgo: 31)
        let purged = try await Retention(paths: f.paths).purgeExpiredAudio(retentionDays: 30, now: f.now)
        #expect(purged == [old])
        #expect(!f.exists(f.paths.tracksDirectory(old)))
        #expect(!f.exists(f.merged(old)))
        #expect(f.exists(f.paths.manifestFile(old)))
        #expect(f.exists(f.paths.transcriptFile(old, .final)))
        #expect(try await f.jobs.load(old) != nil)
        // nothing left to purge the next time
        #expect(try await Retention(paths: f.paths).purgeExpiredAudio(retentionDays: 30, now: f.now) == [])
    }

    @Test func keepsAudioWithinRetentionOrWhenZero() async throws {
        let f = try RetentionFixture()
        let recent = try await f.meeting("20260925-1400-0002", daysAgo: 29)
        let ancient = try await f.meeting("20260716-1400-0003", daysAgo: 100)
        let retention = Retention(paths: f.paths)
        #expect(try await retention.purgeExpiredAudio(retentionDays: 30, now: f.now) == [ancient])
        #expect(f.hasAudio(recent))

        let g = try RetentionFixture()
        let kept = try await g.meeting("20260716-1400-0004", daysAgo: 100)
        #expect(try await Retention(paths: g.paths).purgeExpiredAudio(retentionDays: 0, now: g.now) == [])
        #expect(g.hasAudio(kept))
    }

    @Test func purgeKeepsAudioOfUntranscribedMeetings() async throws {
        let f = try RetentionFixture()
        let recording = try await f.meeting("20260914-1400-0005", daysAgo: 40, status: .recording,
                                            finalTranscript: false, completed: nil)
        let tooShort = try await f.meeting("20260914-1500-0006", daysAgo: 40, status: .tooShort,
                                           finalTranscript: false, completed: nil)
        let untranscribedJob = try await f.meeting("20260914-1600-0007", daysAgo: 40, status: .recorded,
                                                   finalTranscript: true, completed: [])
        let noFinal = try await f.meeting("20260914-1700-0008", daysAgo: 40, status: .recorded,
                                          finalTranscript: false, completed: nil)
        #expect(try await Retention(paths: f.paths).purgeExpiredAudio(retentionDays: 30, now: f.now) == [])
        for id in [recording, tooShort, untranscribedJob, noFinal] { #expect(f.hasAudio(id), "\(id.rawValue)") }
    }

    @Test func deleteMeetingRemovesEverything() async throws {
        let f = try RetentionFixture()
        let id = try await f.meeting("20261020-1400-0009", daysAgo: 4)
        let other = try await f.meeting("20261021-1400-0010", daysAgo: 3)
        let (folder, renamed) = try await f.writeToVault(id)
        let index = folder.appending(path: "_index.md")
        #expect(try String(contentsOf: index, encoding: .utf8).contains("プロジェクト定例"))
        #expect(f.exists(f.paths.vaultStateFile(id)))

        try await Retention(paths: f.paths, services: SharedVaultServices()).deleteMeeting(id, outputFolder: folder.path)

        #expect(!f.exists(f.paths.meetingDirectory(id)))
        #expect(!f.exists(f.paths.transcriptsDirectory(id)))
        #expect(!f.exists(f.paths.vaultStateFile(id)))
        #expect(try await f.jobs.load(id) == nil)
        #expect(!f.exists(renamed))
        #expect(!(try String(contentsOf: index, encoding: .utf8)).contains("プロジェクト定例"))
        // another meeting is untouched
        #expect(f.hasAudio(other))
        #expect(try await f.jobs.load(other) != nil)
    }

    @Test func deleteWithUnavailableFolderDeletesNothing() async throws {
        let f = try RetentionFixture()
        let id = try await f.meeting("20261020-1400-0011", daysAgo: 4)
        let (folder, renamed) = try await f.writeToVault(id)
        let retention = Retention(paths: f.paths, services: SharedVaultServices())
        let missing = folder.appending(path: "not-mounted", directoryHint: .isDirectory)
        for outputFolder in [nil, missing.path] {
            await #expect(throws: RetentionError.outputFolderUnavailable) {
                try await retention.deleteMeeting(id, outputFolder: outputFolder)
            }
            #expect(f.exists(f.paths.meetingDirectory(id)))
            #expect(f.hasAudio(id))
            #expect(f.exists(f.paths.transcriptFile(id, .final)))
            #expect(f.exists(f.paths.vaultStateFile(id)))
            #expect(try await f.jobs.load(id) != nil)
            #expect(f.exists(renamed))
        }
    }

    @Test func deleteNeverWrittenMeetingWithoutFolder() async throws {
        let f = try RetentionFixture()
        let id = try await f.meeting("20261026-1400-0012", daysAgo: 1, status: .tooShort, finalTranscript: false,
                                     completed: [])
        try await Retention(paths: f.paths, services: SharedVaultServices()).deleteMeeting(id, outputFolder: nil)
        #expect(!f.exists(f.paths.meetingDirectory(id)))
        #expect(try await f.jobs.load(id) == nil)
        #expect(!f.exists(f.paths.vaultStateFile(id)))
    }

    @Test func schedulerRunsAtStartAndDaily() async throws {
        let f = try RetentionFixture()
        let settings = SettingsStore(paths: f.paths)
        _ = try await settings.update { $0.audioRetentionDays = 30 }
        let expired = try await f.meeting("20260923-1400-0013", daysAgo: 31)
        let nextDay = try await f.meeting("20260927-1400-0014", daysAgo: 29.5)
        let clock = FakeQueueClock(now: f.now)
        let scheduler = RetentionScheduler(retention: Retention(paths: f.paths), settings: settings, clock: clock)

        await scheduler.start()
        await eventually { !f.exists(f.paths.tracksDirectory(expired)) }
        #expect(!f.exists(f.merged(expired)))
        #expect(f.hasAudio(nextDay))

        clock.advance(by: day)
        await eventually { !f.exists(f.paths.tracksDirectory(nextDay)) }
        #expect(!f.exists(f.merged(nextDay)))
        await scheduler.stop()
    }

    @Test func queueDeleteCancelsRunningStage() async throws {
        let f = try RetentionFixture()
        let id = MeetingID(rawValue: "20261026-1400-0015")
        var m = Samples.manifest
        m.id = id
        m.status = .recorded
        try await f.manifests.save(m)
        let log = CallLog()
        let release = AsyncStream<Void>.makeStream()
        let transcribe = ScriptedStage(name: StageName.transcribe, log: log, release: release.stream)
        let stages: [any QueueStage] = [transcribe] + [StageName.summarize, StageName.writeVault, StageName.updateIndex]
            .map { ScriptedStage(name: $0, log: log) }
        // One isolated services instance for the (vault-writing) stages and the queue, as in production.
        let services = SharedVaultServices()
        let (folder, renamed) = try await f.writeToVault(id, services: services)
        var settings = Settings()
        settings.outputFolder = folder.path
        try await SettingsStore(paths: f.paths).save(settings)
        let queue = PostProcessingQueue(paths: f.paths, stages: stages, activity: NeverRecording(), gate: BatchGate(),
                                        clock: FakeQueueClock(now: f.now), services: services)
        #expect(await queue.services === services)
        await queue.enqueue(id)
        await queue.start()
        await eventually { await log.entries == [StageName.transcribe] }
        #expect(await queue.snapshot().jobs.first?.state == .running)

        try await queue.delete(id)

        #expect(await queue.snapshot().jobs.isEmpty)
        #expect(try await f.jobs.load(id) == nil)
        #expect(!f.exists(f.paths.meetingDirectory(id)))
        #expect(!f.exists(renamed))
        await queue.runUntilIdle()
        #expect(await log.entries == [StageName.transcribe])
        #expect(try await f.jobs.load(id) == nil)
        await queue.stop()
    }
}
