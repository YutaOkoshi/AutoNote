import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct WriteVaultStageTests {
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let titledPath = "2026/2026-10-24_1400_プロジェクト定例.md"
    private static let untitledPath = "2026/2026-10-24_140000.md"

    private struct Fixture {
        let paths: AppPaths
        let manifests: ManifestStore
        let manifest: Manifest
        let outputFolder: URL
    }

    /// A `.generating` meeting with `final.json`, optionally `minutes.json`, plus an empty output folder.
    private func setUp(withMinutes: Bool) async throws -> Fixture {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        var manifest = Samples.manifest
        manifest.status = .generating
        let manifests = ManifestStore(paths: paths)
        try await manifests.save(manifest)
        let final = Transcript(utterances: [u(1, .me, "はじめます")], engine: "whisper.cpp large-v3-turbo",
                               language: manifest.language)
        let url = paths.transcriptFile(manifest.id, .final)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(final).write(to: url)
        let f = Fixture(paths: paths, manifests: manifests, manifest: manifest, outputFolder: try TemporaryDirectory.make())
        if withMinutes { try putMinutes(f) }
        return f
    }

    private func putMinutes(_ f: Fixture) throws {
        try AutoNoteJSON.encoder().encode(Samples.minutes).write(to: f.paths.minutesFile(f.manifest.id))
    }

    private func stage() -> WriteVaultStage {
        WriteVaultStage(timeZone: Self.tokyo, services: SharedVaultServices())
    }

    private func context(_ f: Fixture, outputFolder: String?? = .none) -> StageContext {
        var settings = Settings()
        settings.outputFolder = outputFolder ?? f.outputFolder.path
        return StageContext(paths: f.paths, settings: settings, manifests: f.manifests,
                            now: { Date(timeIntervalSince1970: 1_800_000_000) }, reportProgress: { _ in })
    }

    private func job(_ f: Fixture, summaryFailure: String? = nil, overwriteApproved: Bool = false) -> Job {
        Job(id: f.manifest.id.rawValue, meeting: f.manifest.id, stages: StageName.all,
            completedStages: [StageName.transcribe, StageName.summarize], state: .running, attempts: 0,
            lastError: nil, notBefore: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            summaryFailure: summaryFailure, overwriteApproved: overwriteApproved)
    }

    private func file(_ f: Fixture, _ relative: String) -> URL { f.outputFolder.appending(path: relative) }

    private func read(_ f: Fixture, _ relative: String) throws -> String {
        try String(contentsOf: file(f, relative), encoding: .utf8)
    }

    private func exists(_ f: Fixture, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: file(f, relative).path)
    }

    private var failure: String { SummaryFailureKind.encode(.timedOut, message: "") }

    @Test func nameAndRetryInterval() {
        #expect(WriteVaultStage().name == "write_vault")
        #expect(WriteVaultStage.retryInterval == 300)
    }

    @Test func writesMinutesGeneratedFile() async throws {
        let f = try await setUp(withMinutes: true)
        var j = job(f)
        try await stage().run(&j, context: context(f))
        let text = try read(f, Self.titledPath)
        #expect(text.contains("status: minutes_generated"))
        #expect(text.contains("リリースは来週に決定"))
        #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
        #expect(try await f.manifests.load(f.manifest.id).status == .minutesGenerated)
        #expect(j.completedStages == [StageName.transcribe, StageName.summarize])
    }

    @Test func writesTranscriptOnlyWithSecondsName() async throws {
        let f = try await setUp(withMinutes: false)
        var j = job(f, summaryFailure: failure)
        try await stage().run(&j, context: context(f))
        let text = try read(f, Self.untitledPath)
        #expect(text.contains("status: transcript_only"))
        #expect(text.contains("はじめます"))
        #expect(!exists(f, Self.titledPath))
        #expect(try await f.manifests.load(f.manifest.id).status == .transcriptOnly)
    }

    @Test func renamesUntitledFileWhenMinutesArrive() async throws {
        let f = try await setUp(withMinutes: false)
        let s = stage()
        var first = job(f, summaryFailure: failure)
        try await s.run(&first, context: context(f))
        #expect(exists(f, Self.untitledPath))

        try putMinutes(f)
        var second = job(f)
        try await s.run(&second, context: context(f))
        #expect(exists(f, Self.titledPath))
        #expect(!exists(f, Self.untitledPath))
        #expect(try read(f, Self.titledPath).contains("status: minutes_generated"))
        #expect(try await f.manifests.load(f.manifest.id).status == .minutesGenerated)
    }

    @Test func editedFileAwaitsConfirmationThenForceWrites() async throws {
        let f = try await setUp(withMinutes: true)
        let s = stage()
        var j = job(f)
        try await s.run(&j, context: context(f))
        let original = try read(f, Self.titledPath)
        let edited = original + "利用者のメモ\n"
        try Data(edited.utf8).write(to: file(f, Self.titledPath))

        var again = job(f)
        await #expect(throws: StageError.awaitingConfirmation(path: Self.titledPath)) {
            try await s.run(&again, context: context(f))
        }
        #expect(try read(f, Self.titledPath) == edited)

        var approved = job(f, overwriteApproved: true)
        try await s.run(&approved, context: context(f))
        #expect(try read(f, Self.titledPath) == original)
        #expect(approved.overwriteApproved == false)
    }

    @Test func missingOutputFolderRetriesInFiveMinutes() async throws {
        let f = try await setUp(withMinutes: true)
        var j = job(f)
        await #expect(throws: StageError.retry(after: 300, reason: "output_folder_missing")) {
            try await stage().run(&j, context: context(f, outputFolder: .some(nil)))
        }

        let missing = f.outputFolder.appending(path: "not-mounted", directoryHint: .isDirectory)
        var k = job(f)
        await #expect(throws: StageError.retry(after: 300, reason: "output_folder_unavailable")) {
            try await stage().run(&k, context: context(f, outputFolder: missing.path))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.outputFolder.path).isEmpty)
        #expect(try await f.manifests.load(f.manifest.id).status == .generating)
    }

    @Test func failedRegenerateKeepsExistingMinutes() async throws {
        let f = try await setUp(withMinutes: true)
        let s = stage()
        var first = job(f)
        try await s.run(&first, context: context(f))
        let before = try read(f, Self.titledPath)

        var regen = job(f, summaryFailure: failure)
        try await s.run(&regen, context: context(f))
        #expect(try read(f, Self.titledPath) == before)
        #expect(!exists(f, Self.untitledPath))
        #expect(regen.completedStages.contains(StageName.updateIndex))
        #expect(regen.completedStages.contains(StageName.automations))
        #expect(try await f.manifests.load(f.manifest.id).status == .minutesGenerated)
    }
}
