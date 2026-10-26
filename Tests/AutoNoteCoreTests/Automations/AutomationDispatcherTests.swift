import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct AutomationDispatcherTests {
    private static let id = MeetingID(rawValue: "20261024-1400-a1b2")

    private struct Fixture {
        let root: URL
        let paths: AppPaths
        let manifests: ManifestStore
        let file: AutomationsFile
        let runner: AutomationRunner
        let notifier = FakeUserNotifier()
        let outputFolder: URL
        var out: URL { root.appending(path: "out") }

        init(_ defs: [AutomationDefinition]) throws {
            root = try TemporaryDirectory.make()
            paths = AppPaths(root: root.appending(path: "app"))
            manifests = ManifestStore(paths: paths)
            outputFolder = root.appending(path: "vault")
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appending(path: "out"), withIntermediateDirectories: true)
            file = AutomationsFile(url: paths.automationsFile)
            try file.save(defs)
            runner = AutomationRunner(logsDirectory: root.appending(path: "logs"),
                                      ledgerFile: root.appending(path: "ledger.json"), shell: ["/bin/zsh", "-fc"])
        }

        var dispatcher: AutomationDispatcher { AutomationDispatcher(file: file, runner: runner, notifier: notifier) }

        func stage() -> AutomationsStage {
            let writer = VaultWriter(outputFolder: outputFolder, paths: paths)
            let folder = outputFolder
            return AutomationsStage(dispatcher: dispatcher, vault: { (folder: folder, writer: writer) })
        }

        func context() -> StageContext {
            StageContext(paths: paths, settings: Settings(), manifests: manifests, now: { Date() }, reportProgress: { _ in })
        }

        func save(status: MeetingStatus, title: String? = nil) async throws {
            var m = Samples.manifest
            m.status = status
            m.title = title
            try await manifests.save(m)
        }

        func def(_ name: String, on: AutomationTrigger = .minutesGenerated, enabled: Bool = true,
                 command: String? = nil) -> AutomationDefinition {
            AutomationDefinition(name: name, enabled: enabled, on: on,
                                 command: command ?? "echo $AUTONOTE_EVENT > '\(out.path)/\(name).txt'", timeoutSec: 20)
        }
    }

    private func job(_ id: String, generation: Int = 0) -> Job {
        Job(id: id, meeting: MeetingID(rawValue: id), stages: StageName.all, completedStages: [], state: .running,
            attempts: 0, lastError: nil, notBefore: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            generation: generation)
    }

    @Test func triggerMapping() {
        #expect(AutomationsStage.trigger(for: .minutesGenerated) == .minutesGenerated && AutomationsStage.trigger(for: .transcriptOnly) == .transcriptOnly)
        #expect(AutomationsStage.trigger(for: .failed) == nil && AutomationsStage.trigger(for: .recorded) == nil)
    }

    @Test func dedupeKeyUsesGeneration() {
        #expect(AutomationsStage.dedupeKey(job("20261024-1400-a1b2", generation: 2)) == "20261024-1400-a1b2:2")
    }

    @Test func regenerationRunsAgain() async throws {
        let fx = try Fixture([])
        try fx.file.save([fx.def("A")])
        try await fx.save(status: .minutesGenerated)
        let stage = fx.stage()
        var j = job(Self.id.rawValue, generation: 2)
        try await stage.run(&j, context: fx.context())
        try await stage.run(&j, context: fx.context())
        #expect(await fx.runner.recentRuns(limit: 10).count == 1)
        var j3 = job(Self.id.rawValue, generation: 3)
        try await stage.run(&j3, context: fx.context())
        #expect(await fx.runner.recentRuns(limit: 10).count == 2)
    }

    @Test func pathsFromAppPathsAndVaultRecord() async throws {
        let fx = try Fixture([])
        let command = "print -rn -- \"$AUTONOTE_FILE|$AUTONOTE_JSON\" > '\(fx.out.path)/paths.txt'"
        try fx.file.save([AutomationDefinition(name: "P", on: .minutesGenerated, command: command),
                          AutomationDefinition(name: "T", on: .transcriptOnly, command: command)])
        let record = VaultWriteRecord(meeting: Self.id, relativePath: "Meetings/2026/x.md", sha256: "x", writtenAt: Date())
        try FileManager.default.createDirectory(at: fx.paths.vaultStateDirectory, withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(record).write(to: fx.paths.vaultStateFile(Self.id))
        try FileManager.default.createDirectory(at: fx.paths.minutesFile(Self.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fx.paths.minutesFile(Self.id))

        try await fx.save(status: .minutesGenerated)
        var j = job(Self.id.rawValue)
        try await fx.stage().run(&j, context: fx.context())
        let text = try String(contentsOf: fx.out.appending(path: "paths.txt"), encoding: .utf8)
        #expect(text == "\(fx.outputFolder.path)/Meetings/2026/x.md|\(fx.paths.minutesFile(Self.id).path)")

        try await fx.save(status: .transcriptOnly)
        var j2 = job(Self.id.rawValue, generation: 1)
        try await fx.stage().run(&j2, context: fx.context())
        let text2 = try String(contentsOf: fx.out.appending(path: "paths.txt"), encoding: .utf8)
        #expect(text2 == "\(fx.outputFolder.path)/Meetings/2026/x.md|")

        try FileManager.default.removeItem(at: fx.paths.vaultStateFile(Self.id))
        var j3 = job(Self.id.rawValue, generation: 2)
        try await fx.stage().run(&j3, context: fx.context())
        let text3 = try String(contentsOf: fx.out.appending(path: "paths.txt"), encoding: .utf8)
        #expect(text3 == "|")
    }

    @Test func runsOnlyMatchingRunnableInFileOrder() async throws {
        let fx = try Fixture([])
        try fx.file.save([fx.def("A"), fx.def("B", enabled: false), fx.def("C", on: .transcriptOnly), fx.def("D")])
        let ctx = AutomationContextBuilder.make(event: .minutesGenerated, manifest: Samples.manifest, file: nil, minutesJSON: nil)
        let records = await fx.dispatcher.dispatch(.minutesGenerated, context: ctx, dedupeKey: "k")
        #expect(records.map(\.name) == ["A", "D"])
    }

    @Test func failureDoesNotThrowAndNotifies() async throws {
        let fx = try Fixture([])
        try fx.file.save([fx.def("A", command: "exit 1")])
        try await fx.save(status: .minutesGenerated)
        var j = job(Self.id.rawValue)
        try await fx.stage().run(&j, context: fx.context())
        #expect(await fx.notifier.posted == [.automationFailed(name: "A", Self.id)])
    }

    @Test func permissionDisabledRunsNothing() async throws {
        let fx = try Fixture([])
        try fx.file.save([fx.def("A")])
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: fx.paths.automationsFile.path)
        let ctx = AutomationContextBuilder.make(event: .minutesGenerated, manifest: Samples.manifest, file: nil, minutesJSON: nil)
        let records = await fx.dispatcher.dispatch(.minutesGenerated, context: ctx, dedupeKey: "k")
        #expect(records.isEmpty)
    }

    @Test func contextFromManifest() {
        var m = Samples.manifest
        m.title = nil
        let ctx = AutomationContextBuilder.make(event: .recordingStarted, manifest: m, file: nil, minutesJSON: nil,
                                                timeZone: Samples.tokyo)
        #expect(ctx.title == "" && ctx.date == "2026-10-24" && ctx.start == "14:00" && ctx.file == nil)
        #expect(ctx.meetingID == m.id && ctx.event == .recordingStarted)
    }

    @Test func recordingEventsFireStartedAndStoppedOnce() async throws {
        let fx = try Fixture([])
        try fx.file.save([fx.def("S", on: .recordingStarted), fx.def("E", on: .recordingStopped)])
        try await fx.save(status: .recording)
        let trigger = RecordingAutomationTrigger(dispatcher: fx.dispatcher, manifests: fx.manifests)
        let m = Samples.manifest
        await trigger.handle(.started(m.id))
        await trigger.handle(.bookmarked(Bookmark(at: .zero)))
        await trigger.handle(.stopped(m, .manual))
        await trigger.handle(.stopped(m, .manual))
        let runs = await fx.runner.recentRuns(limit: 10)
        #expect(runs.filter { $0.event == .recordingStarted }.count == 1)
        #expect(runs.filter { $0.event == .recordingStopped }.count == 1)
        #expect(runs.count == 2)
    }
}
