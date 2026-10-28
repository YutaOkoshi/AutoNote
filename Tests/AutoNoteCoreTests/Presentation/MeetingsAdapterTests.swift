import Testing
import Foundation
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct MeetingsAdapterTests {
    struct Fixture {
        let paths: AppPaths
        let folder: URL
        let manifests: ManifestStore
        let output: OutputFolderServices
        let adapter: MeetingsAdapter
        let id = Samples.manifest.id

        init() async throws {
            let root = try TemporaryDirectory.make()
            paths = AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory))
            try paths.createBaseDirectories()
            folder = root.appending(path: "Vault", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            manifests = ManifestStore(paths: paths)
            output = OutputFolderServices(paths: paths, services: SharedVaultServices())
            adapter = MeetingsAdapter(paths: paths, manifests: manifests, settings: SettingsStore(paths: paths), output: output,
                                      importer: AudioImporter(paths: paths, manifests: manifests),
                                      crashRecovery: CrashRecovery(paths: paths, manifests: manifests),
                                      route: { _ in }, appVersion: "0.1.0")
            // Fixture meeting 20261024-1400-a1b2: manifest and final.json.
            try await manifests.save(Samples.manifest)
            let final = Transcript(utterances: [u(1, .me, "では始めます"), u(5, .other, "お願いします")],
                                   engine: FixtureLibrary.engine, language: .ja)
            try FileManager.default.createDirectory(at: paths.transcriptsDirectory(id), withIntermediateDirectories: true)
            try AutoNoteJSON.encoder().encode(final).write(to: paths.transcriptFile(id, .final))
        }

        func minutes(title: String) -> MinutesOutput {
            var m = Samples.minutes
            m.title = title
            return m
        }

        func savedMinutes() throws -> MinutesOutput {
            try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(contentsOf: paths.minutesFile(id)))
        }
    }

    @Test func saveMinutesWritesVaultThenJSON() async throws {
        let f = try await Fixture()
        _ = try await f.output.rebuild(outputFolder: f.folder.path)
        let outcome = try await f.adapter.saveMinutes(f.id, f.minutes(title: "新しいタイトル"), renameFile: false, overwrite: false)
        guard case .saved(let url) = outcome else { Issue.record("expected .saved, got \(outcome)"); return }
        #expect(try f.savedMinutes().title == "新しいタイトル")
        #expect(try await f.manifests.load(f.id).title == "新しいタイトル")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("新しいタイトル"))
        #expect(FileManager.default.fileExists(atPath: f.folder.appending(path: "_index.md").path))
    }

    @Test func externalEditIsReportedThenForced() async throws {
        let f = try await Fixture()
        _ = try await f.output.rebuild(outputFolder: f.folder.path)
        guard case .saved(let url) = try await f.adapter.saveMinutes(f.id, f.minutes(title: "一回目"), renameFile: false, overwrite: false) else {
            Issue.record("first save did not write"); return
        }
        let edited = "---\nautonote_id: \(f.id.rawValue)\n---\n外で書き換えた\n"
        try Data(edited.utf8).write(to: url)

        let second = try await f.adapter.saveMinutes(f.id, f.minutes(title: "二回目"), renameFile: false, overwrite: false)
        #expect(second == .externallyEdited(url))
        #expect(try String(contentsOf: url, encoding: .utf8) == edited)
        // M5: 上書きを断られたら minutes.json と manifest のタイトルは前の保存のまま
        #expect(try f.savedMinutes().title == "一回目")
        #expect(try await f.manifests.load(f.id).title == "一回目")

        let forced = try await f.adapter.saveMinutes(f.id, f.minutes(title: "二回目"), renameFile: false, overwrite: true)
        guard case .saved(let forcedURL) = forced else { Issue.record("expected .saved, got \(forced)"); return }
        #expect(try String(contentsOf: forcedURL, encoding: .utf8).contains("二回目"))
        #expect(try f.savedMinutes().title == "二回目")
        #expect(try await f.manifests.load(f.id).title == "二回目")
    }

    @Test func rowsKeepTitleAndPathAfterOutputFolderChange() async throws {
        // 被験者 4: 完成した会議のあとで保存先を変えると、一覧が「（無題）」に戻り「Finder で表示」「最新の議事録を
        // 開く」が無効になった。書いた議事録は古いフォルダに残るので、そのタイトルとパスを引き続き使う。
        let f = try await Fixture()
        try AutoNoteJSON.encoder().encode(Samples.minutes).write(to: f.paths.minutesFile(f.id))
        var settings = Settings()
        settings.outputFolder = f.folder.path
        let context = StageContext(paths: f.paths, settings: settings, manifests: f.manifests,
                                   now: { Date(timeIntervalSince1970: 1_800_000_000) }, reportProgress: { _ in })
        var job = Job(id: f.id.rawValue, meeting: f.id, stages: StageName.all,
                      completedStages: [StageName.transcribe, StageName.summarize], state: .running, attempts: 0,
                      lastError: nil, notBefore: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await WriteVaultStage(timeZone: Samples.tokyo, services: SharedVaultServices()).run(&job, context: context)
        _ = try await f.output.rebuild(outputFolder: f.folder.path)
        let before = try #require(try await f.adapter.rows().first)
        #expect(before.title == "プロジェクト定例")
        let path = try #require(before.filePath)
        #expect(FileManager.default.fileExists(atPath: path))

        let other = try TemporaryDirectory.make().appending(path: "新しい保存先", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try await f.output.rebuild(outputFolder: other.path)
        let after = try #require(try await f.adapter.rows().first)
        #expect(after.title == "プロジェクト定例")
        #expect(after.filePath == path)
        #expect(after.state == .minutesGenerated)
        #expect(try await f.adapter.latestMinutesFile()?.path == path)
        #expect(FileManager.default.fileExists(atPath: path))   // the note is not moved

        // A note that no longer exists gives no path (「Finder で表示」 stays disabled).
        try FileManager.default.removeItem(atPath: path)
        #expect(try await f.adapter.rows().first?.filePath == nil)
    }

    @Test func saveWithoutOutputFolderFails() async throws {
        let f = try await Fixture()
        _ = try await f.output.rebuild(outputFolder: nil)
        await #expect(throws: AppCommandError.failed("保存先が見つかりません")) {
            try await f.adapter.saveMinutes(f.id, f.minutes(title: "x"), renameFile: false, overwrite: false)
        }
        _ = try await f.output.rebuild(outputFolder: f.folder.appending(path: "missing").path)
        await #expect(throws: AppCommandError.failed("保存先が見つかりません")) {
            try await f.adapter.saveMinutes(f.id, f.minutes(title: "x"), renameFile: false, overwrite: false)
        }
    }

    @Test func liveSummaryReadsStoredFile() async throws {
        // LiveSummaryStore で保存 → adapter.liveSummary(id) == 同じ値。ファイルが無い会議 → nil
        let f = try await Fixture()
        #expect(try await f.adapter.liveSummary(f.id) == nil)
        let s = LiveSummaryState(now: "見積もりの確認", decisions: ["リリースは来週"],
                                 todos: [LiveSummaryTodo(text: "資料を送る", owner: "佐藤")], consumedThrough: 85,
                                 updatedAt: Samples.start)
        try LiveSummaryStore(paths: f.paths).save(s, for: f.id)
        #expect(try await f.adapter.liveSummary(f.id) == s)
        #expect(try await f.adapter.liveSummary(MeetingID(rawValue: "20261024-1500-c3d4")) == nil)
    }
}
