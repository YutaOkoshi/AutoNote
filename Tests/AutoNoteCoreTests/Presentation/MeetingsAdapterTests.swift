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

    @Test func saveWithoutOutputFolderFails() async throws {
        let f = try await Fixture()
        _ = try await f.output.rebuild(outputFolder: nil)
        await #expect(throws: AppCommandError.failed("出力フォルダが見つかりません")) {
            try await f.adapter.saveMinutes(f.id, f.minutes(title: "x"), renameFile: false, overwrite: false)
        }
        _ = try await f.output.rebuild(outputFolder: f.folder.appending(path: "missing").path)
        await #expect(throws: AppCommandError.failed("出力フォルダが見つかりません")) {
            try await f.adapter.saveMinutes(f.id, f.minutes(title: "x"), renameFile: false, overwrite: false)
        }
    }
}
