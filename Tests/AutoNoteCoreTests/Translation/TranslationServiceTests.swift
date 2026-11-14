@testable import AutoNoteCore
import AutoNoteTestSupport
import CryptoKit
import Foundation
import Synchronization
import Testing

/// A data directory with one meeting, its final transcript and a fake model file.
struct TranslationFixture {
    let paths: AppPaths
    let id = MeetingID(rawValue: "20261114-1000-a1b2")
    let modelURL: URL
    let settings: LockedBox<Settings>
    let store: TranslationStore

    static let utterances = [
        utterance(0, "We moved about sixty percent of the tenants over the weekend."),
        utterance(4, "残りも今月末までにいけそうですか。", .me),
        utterance(8, "It slipped twice already, right?"),
        utterance(11, "Put me down. I'll take it."),
    ]

    init(mode: TranslationMode = .afterRecording, accepted: Bool = true, writeTranscript: Bool = true) throws {
        paths = AppPaths(root: try TemporaryDirectory.make())
        try paths.createBaseDirectories()
        store = TranslationStore(paths: paths)
        modelURL = paths.translationModelsDirectory.appending(path: "fake.gguf")
        var s = Settings()
        s.translationMode = mode
        s.translationLicenseVersion = accepted ? TranslationLicense.version : nil
        settings = LockedBox(s)
        if writeTranscript { try writeFinal(Self.utterances) }
    }

    func writeFinal(_ utterances: [Utterance]) throws {
        try FileManager.default.createDirectory(at: paths.transcriptsDirectory(id), withIntermediateDirectories: true)
        let t = Transcript(utterances: utterances, engine: "fake", language: .auto)
        try AutoNoteJSON.encoder().encode(t).write(to: paths.transcriptFile(id, .final))
    }

    func finalData() throws -> Data { try Data(contentsOf: paths.transcriptFile(id, .final)) }

    func deps(_ completer: any TextCompleting, installed: Bool = true, runtime: Bool = true,
              profile: MachineProfile = .init(kind: .appleSilicon, physicalCores: 8, physicalMemory: 32 << 30),
              now: Date = Date(timeIntervalSince1970: 0)) -> TranslationDependencies {
        let settings = settings, url = modelURL
        return TranslationDependencies(
            settings: { settings.withLock { $0 } },
            saveShown: { v in settings.withLock { $0.translationShown = v } },
            store: store, runtime: TranslationRuntime(completer: completer), runtimeAvailable: runtime,
            installedModel: { _ in installed ? url : nil }, profile: profile, now: { now })
    }
}

/// A shared, lockable value.
final class LockedBox<T: Sendable>: Sendable {
    private let value: Mutex<T>
    init(_ v: T) { value = Mutex(v) }
    func withLock<R: Sendable>(_ body: (inout T) -> R) -> R { value.withLock { body(&$0) } }
}

/// Collects a stream's elements.
final class Collected<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    init() {}
    var values: [T] { items.withLock { $0 } }
    func append(_ v: T) { items.withLock { $0.append(v) } }

    static func from(_ stream: AsyncStream<T>) -> (Collected<T>, Task<Void, Never>) {
        let c = Collected<T>()
        let t = Task { for await v in stream { c.append(v) } }
        return (c, t)
    }
}

func eventually(_ timeout: Duration = .seconds(2), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite struct TranslationRuntimeTests {
    @Test func leaseLoadsUnloadsAndIsExclusive() async throws {
        let fake = FakeTextCompleter(delay: .milliseconds(20))
        let runtime = TranslationRuntime(completer: fake)
        let url = URL(filePath: "/tmp/m.gguf")
        let order = Collected<String>()
        async let a: Void = runtime.withModel(url) { t in
            order.append("a-start")
            _ = try await t.translate("Hello.", from: .en, to: .ja, history: [])
            order.append("a-end")
        }
        try await Task.sleep(for: .milliseconds(5))
        async let b: Void = runtime.withModel(url) { _ in order.append("b") }
        _ = try await (a, b)
        #expect(order.values == ["a-start", "a-end", "b"])
        #expect(fake.snapshot.loads.count == 2 && fake.snapshot.unloads == 2)
        #expect(fake.snapshot.loaded == nil)
        #expect(!(await runtime.isHeld))
    }

    @Test func unloadsAfterAFailureAndALoadFailure() async {
        let failing = FakeTextCompleter(failOnCall: 1)
        let runtime = TranslationRuntime(completer: failing)
        await #expect(throws: FakeTextCompleter.Failure.self) {
            try await runtime.withModel(URL(filePath: "/m")) { t in _ = try await t.translate("Hi.", from: .en, to: .ja, history: []) }
        }
        #expect(failing.snapshot.unloads == 1)
        let noLoad = FakeTextCompleter(failLoad: true)
        let r2 = TranslationRuntime(completer: noLoad)
        await #expect(throws: FakeTextCompleter.Failure.self) { try await r2.withModel(URL(filePath: "/m")) { _ in } }
        #expect(!(await r2.isHeld))
    }

    @Test func aCancelledWaiterGivesUp() async throws {
        let runtime = TranslationRuntime(completer: FakeTextCompleter())
        let gate = AsyncStream<Void>.makeStream()
        let holder = Task { try await runtime.withModel(URL(filePath: "/m")) { _ in for await _ in gate.stream {} } }
        #expect(await eventually { await runtime.isHeld })
        let waiter = Task { try await runtime.withModel(URL(filePath: "/m")) { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        gate.continuation.finish()
        try await holder.value
        #expect(!(await runtime.isHeld))
    }

    @Test func theUnavailableRuntimeFailsCleanly() async {
        let runtime = TranslationRuntime(completer: UnavailableTextCompleter())
        await #expect(throws: TranslationError.runtimeUnavailable) { try await runtime.withModel(URL(filePath: "/m")) { _ in } }
        #expect(TranslationRuntimeFactory.makeOnDevice() == nil)
    }
}

@Suite struct TranslationInstallerTests {
    @Test func noDownloadBeforeTheLicenseIsAccepted() async throws {
        let blob = Data("gguf".utf8)
        let model = TranslationModel(name: "2b", repository: "pfnet/x", revision: String(repeating: "a", count: 40),
                                     remoteFileName: "x.gguf", sizeBytes: Int64(blob.count),
                                     sha256: SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined())
        let downloader = FakeModelDownloader(payload: blob)
        let dir = try TemporaryDirectory.make()
        let settings = LockedBox(Settings())
        let installer = TranslationModelInstaller(
            manager: TranslationModelManager(directory: dir, catalog: [model], downloader: downloader),
            settings: { settings.withLock { $0 } })
        await #expect(throws: TranslationError.licenseNotAccepted) { _ = try await installer.download("2b") { _ in } }
        #expect(downloader.callCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

        settings.withLock { $0.translationLicenseVersion = TranslationLicense.version }
        let url = try await installer.download("2b") { _ in }
        #expect(downloader.callCount == 1)
        #expect(url.lastPathComponent == "x-aaaaaaaa.gguf")
        #expect(await installer.fileURL(model) == url)
        try await installer.delete("2b")
        #expect(await installer.installed().isEmpty)
    }
}

@Suite struct TranslationServiceTests {
    private func queue(_ items: [(String, String, String)]) -> QueueStatus {
        QueueStatus(items: items.map { QueueItemDTO(meetingID: $0.0, stage: $0.1, state: $0.2) })
    }

    @Test func translatesOnceTheJobLeavesTranscribeAndNeverTouchesTheMeeting() async throws {
        let f = try TranslationFixture()
        let manifestBefore = try? Data(contentsOf: f.paths.manifestFile(f.id))
        let finalBefore = try f.finalData()
        let fake = FakeTextCompleter()
        let service = TranslationService(f.deps(fake))
        let (updates, collector) = Collected.from(await service.updates())
        let (stream, continuation) = AsyncStream<QueueStatus>.makeStream()
        let follower = Task { await service.follow(queue: stream) }

        continuation.yield(queue([(f.id.rawValue, StageName.transcribe, "running")]))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.snapshot.prompts.isEmpty)   // still transcribing: nothing yet

        continuation.yield(queue([(f.id.rawValue, StageName.summarize, "running")]))
        #expect(await eventually { f.store.load(f.id)?.complete == true })
        await service.waitForJob(f.id)
        let doc = try #require(f.store.load(f.id))
        #expect(doc.entries.count == 4 && doc.total == 4 && doc.model == "2b")
        #expect(doc.sourceDigest == TranslationKey.digest(TranslationFixture.utterances))
        // The transcript and the manifest are exactly as before (spec: the original is never rewritten).
        #expect(try f.finalData() == finalBefore)
        #expect((try? Data(contentsOf: f.paths.manifestFile(f.id))) == manifestBefore)
        #expect(fake.snapshot.unloads == 1 && fake.snapshot.loaded == nil)

        // The summary finishing (and the job leaving the queue) does not translate again.
        continuation.yield(queue([]))
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.snapshot.prompts.count == 4)
        continuation.finish()
        await follower.value
        #expect(await eventually { updates.values.contains(.job(f.id, nil, revision: 1)) })
        #expect(updates.values.contains { if case .job(_, .running(let p), _) = $0 { p == TranslationProgress(done: 4, total: 4) } else { false } })
        collector.cancel()
        #expect(await service.meetingTranslation(f.id).status == .complete)
    }

    @Test func aJobGoneStraightFromTranscribeAlsoCounts() async throws {
        let f = try TranslationFixture()
        let fake = FakeTextCompleter()
        let service = TranslationService(f.deps(fake))
        let (stream, continuation) = AsyncStream<QueueStatus>.makeStream()
        continuation.yield(queue([(f.id.rawValue, StageName.transcribe, "running")]))
        continuation.yield(queue([]))
        continuation.finish()
        await service.follow(queue: stream)
        await service.waitForJob(f.id)
        #expect(f.store.load(f.id)?.complete == true)
    }

    @Test func nothingAutomaticWhenOffNotAcceptedNotInstalledOrOld() async throws {
        for variant in 0..<4 {
            let f = try TranslationFixture(mode: variant == 0 ? .off : .afterRecording, accepted: variant != 1)
            let fake = FakeTextCompleter()
            // variant 3: the transcript was written before this launch.
            let deps = f.deps(fake, installed: variant != 2, now: variant == 3 ? Date().addingTimeInterval(3600) : Date(timeIntervalSince1970: 0))
            let service = TranslationService(deps)
            let (stream, continuation) = AsyncStream<QueueStatus>.makeStream()
            continuation.yield(queue([(f.id.rawValue, StageName.summarize, "running")]))
            continuation.finish()
            await service.follow(queue: stream)
            await service.waitForJob(f.id)
            #expect(fake.snapshot.loads.isEmpty, "variant \(variant)")
            #expect(f.store.load(f.id) == nil, "variant \(variant)")
            #expect(await service.state(f.id) == nil, "variant \(variant)")
        }
    }

    @Test func aFailureOnlyMarksTheTranslationAndRetryContinues() async throws {
        let f = try TranslationFixture()
        let fake = FakeTextCompleter(failOnCall: 3)
        let service = TranslationService(f.deps(fake))
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        guard case .failed(let message) = await service.state(f.id) else {
            Issue.record("expected failed")
            return
        }
        #expect(message.hasPrefix("翻訳できませんでした"))
        #expect(await service.meetingTranslation(f.id).status == .partial(done: 2, total: 4))
        #expect(!FileManager.default.fileExists(atPath: f.paths.manifestFile(f.id).path))
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        #expect(await service.state(f.id) == nil)
        #expect(f.store.load(f.id)?.complete == true)
        // The retry continued after the two done lines: 2 + 1 failed + 2 = 5 prompts in all.
        #expect(fake.snapshot.prompts.count == 5)
    }

    @Test func manualTranslateNeedsATranscriptAndAUsableModel() async throws {
        let none = try TranslationFixture(writeTranscript: false)
        await #expect(throws: AppCommandError.self) { try await TranslationService(none.deps(FakeTextCompleter())).translate(none.id) }
        let f = try TranslationFixture(mode: .off)
        let fake = FakeTextCompleter()
        // Off still allows the manual run (spec 9).
        let service = TranslationService(f.deps(fake))
        #expect(await service.availability() == .ready)
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        #expect(f.store.load(f.id)?.complete == true)
        #expect(await TranslationService(f.deps(fake, runtime: false)).availability() == .runtimeUnavailable)
        #expect(await TranslationService(f.deps(fake, installed: false)).availability() == .modelNotInstalled(TranslationModelCatalog.model(named: "2b")!))
        let notAccepted = try TranslationFixture(accepted: false)
        #expect(await TranslationService(notAccepted.deps(fake)).availability() == .licenseNotAccepted)
        await #expect(throws: AppCommandError.self) { try await TranslationService(notAccepted.deps(fake)).translate(notAccepted.id) }
    }

    @Test func aRedoneTranscriptIsStaleAndRetranslatedFromScratch() async throws {
        let f = try TranslationFixture()
        let fake = FakeTextCompleter()
        let service = TranslationService(f.deps(fake))
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        var redone = TranslationFixture.utterances
        redone[0].text = "We moved most of the tenants."
        try f.writeFinal(redone)
        #expect(await service.meetingTranslation(f.id).status == .stale)
        #expect(await service.meetingTranslation(f.id).byIndex.isEmpty)
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        let t = await service.meetingTranslation(f.id)
        #expect(t.status == .complete)
        #expect(t.byIndex[0]?.text == "JA: We moved most of the tenants.")
    }

    @Test func pausesWhileRecordingAndContinuesAfter() async throws {
        let f = try TranslationFixture()
        let fake = FakeTextCompleter(delay: .milliseconds(20))
        let service = TranslationService(f.deps(fake))
        try await service.translate(f.id)
        #expect(await eventually { fake.snapshot.prompts.count >= 1 })
        await service.setRecording(true)
        #expect(await eventually {
            if case .waitingForRecording = await service.state(f.id) { true } else { false }
        })
        let during = fake.snapshot.prompts.count
        #expect(fake.snapshot.loaded == nil)   // the model is released for the recording
        try await Task.sleep(for: .milliseconds(80))
        #expect(fake.snapshot.prompts.count == during)
        await service.setRecording(false)
        await service.waitForJob(f.id)
        #expect(f.store.load(f.id)?.complete == true)
        #expect(fake.snapshot.prompts.count == 4)
        #expect(fake.snapshot.loads.count == 2)
    }

    @Test func completingTheFinalTranslationRemovesTheLiveOne() async throws {
        let f = try TranslationFixture()
        try f.store.saveLive(LiveTranslationDocument(model: "2b", target: .auto, lines: []), for: f.id)
        let service = TranslationService(f.deps(FakeTextCompleter()))
        try await service.translate(f.id)
        await service.waitForJob(f.id)
        #expect(f.store.loadLive(f.id) == nil)
    }

    @Test func shutdownCancelsAndUnloads() async throws {
        let f = try TranslationFixture()
        let fake = FakeTextCompleter(hang: true)
        let service = TranslationService(f.deps(fake))
        try await service.translate(f.id)
        #expect(await eventually { fake.snapshot.prompts.count == 1 })
        await service.shutdown()
        #expect(await service.state(f.id) == nil)
        #expect(fake.snapshot.loaded == nil)
        #expect(fake.snapshot.unloads >= 1)
    }

    @Test func shownIsSavedThroughTheSettings() async throws {
        let f = try TranslationFixture()
        let service = TranslationService(f.deps(FakeTextCompleter()))
        await service.setShown(false)
        #expect(f.settings.withLock { $0.translationShown } == false)
    }
}
