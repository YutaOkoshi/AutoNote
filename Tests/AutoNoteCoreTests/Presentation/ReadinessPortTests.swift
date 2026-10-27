import AutoNoteCore
import AutoNoteTestSupport
import CryptoKit
import Foundation
import Synchronization
import Testing

/// Calls `progress` `steps` times with growing byte counts, then writes the payload; or throws the next scripted error.
private final class ScriptedDownloader: ModelDownloading, Sendable {
    private let payload: Data
    private let steps: Int
    private let errors: Mutex<[any Error]>
    private let calls = Mutex(0)

    init(payload: Data, steps: Int = 2, errors: [any Error] = []) {
        self.payload = payload
        self.steps = steps
        self.errors = Mutex(errors)
    }

    var callCount: Int { calls.withLock { $0 } }

    func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        calls.withLock { $0 += 1 }
        if let error = errors.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw error }
        let total = Int64(payload.count)
        for i in 1...steps { progress(total * Int64(i) / Int64(steps), total) }
        try payload.write(to: destination)
    }
}

@Suite struct ReadinessPortTests {
    private let payload = Data("fake-base-model!".utf8)  // even length, so half the bytes is exactly 0.5

    private func catalogEntry(_ blob: Data) -> WhisperModel {
        WhisperModel(name: "base", url: URL(string: "https://example.invalid/ggml-base.bin")!,
                     sizeBytes: Int64(blob.count),
                     sha256: SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined())
    }

    private struct Fixture {
        let port: LiveReadinessPort
        let settings: SettingsStore
        let models: ModelManager
        let opener: FakeFileOpener
    }

    private func make(downloader: any ModelDownloading, payload blob: Data? = nil, available: Bool = true,
                      locate: @escaping @Sendable () async -> String? = { nil },
                      isExecutable: @escaping @Sendable (String) -> Bool = { _ in false },
                      configure: @escaping @Sendable (inout Settings) -> Void = { _ in }) async throws -> Fixture {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let settings = SettingsStore(paths: paths)
        _ = try await settings.update(configure)
        let models = ModelManager(directory: try TemporaryDirectory.make(), catalog: [catalogEntry(blob ?? payload)], downloader: downloader)
        let catalog = EngineCatalog(machine: .intel,
                                    speech: FakeSpeechCapabilities(speechAvailable: false, speechLocales: [], dictationLocales: []),
                                    installedModels: { await models.installed().map(\.name) })
        let opener = FakeFileOpener()
        let port = LiveReadinessPort(settings: settings, outputFolder: FakeOutputFolderPort(available: available), models: models,
                                     catalog: catalog, opener: opener, locate: locate, isExecutable: isExecutable)
        return Fixture(port: port, settings: settings, models: models, opener: opener)
    }

    /// Reads `iterator` until a value matching `stop` arrives; returns everything read, including that value.
    private func collect(_ iterator: inout AsyncStream<Readiness.Model>.Iterator,
                         until stop: (Readiness.Model) -> Bool) async -> [Readiness.Model] {
        var out: [Readiness.Model] = []
        while let next = await iterator.next() {
            out.append(next)
            if stop(next) { break }
        }
        return out
    }

    private static func isTerminal(_ m: Readiness.Model) -> Bool {
        switch m {
        case .installed, .failed: true
        default: false
        }
    }

    @Test func currentReadsSettingsFolderAndClaude() async throws {
        let folder = try TemporaryDirectory.make().path
        let f = try await make(downloader: ScriptedDownloader(payload: payload), available: true,
                               isExecutable: { $0 == "/fake/claude" },
                               configure: { $0.outputFolder = folder; $0.claudePath = "/fake/claude" })
        #expect(await f.port.current() == Readiness(outputFolder: .init(path: folder, available: true), model: .none,
                                                    claude: .init(path: "/fake/claude", found: true)))
    }

    @Test func unsetFolderIsUnavailableWithEmptyPath() async throws {
        let f = try await make(downloader: ScriptedDownloader(payload: payload), available: true,
                               configure: { $0.outputFolder = nil; $0.claudePath = nil })
        let r = await f.port.current()
        #expect(r.outputFolder == .init(path: "", available: false))
        #expect(r.claude == .init(path: nil, found: false))
    }

    @Test func firstRunDownloadStreamsProgress() async throws {
        let f = try await make(downloader: ScriptedDownloader(payload: payload))
        var it = await f.port.updates().makeAsyncIterator()
        #expect(await it.next() == Readiness.Model.none)
        #expect(await f.port.startFirstRunDownload(isDataDirectoryOverridden: false) == "base")
        let seen = await collect(&it, until: Self.isTerminal)
        #expect(seen.contains(.downloading("base", fraction: 0.5)))
        #expect(seen.last == .installed("base"))
        #expect(await f.port.current().model == .installed("base"))
    }

    @Test func progressIsYieldedPerWholePercent() async throws {
        let big = Data(repeating: 7, count: 20_000)
        let f = try await make(downloader: ScriptedDownloader(payload: big, steps: 10_000), payload: big)
        let port = f.port
        var it = await port.updates().makeAsyncIterator()
        _ = await it.next()
        #expect(await port.startFirstRunDownload(isDataDirectoryOverridden: false) == "base")
        let seen = await collect(&it, until: Self.isTerminal)
        let fractions = seen.compactMap { m -> Double? in
            if case .downloading(_, let fraction) = m { return fraction }
            return nil
        }
        #expect(fractions.count <= 101)
        #expect(fractions.count >= 2)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(seen.last == .installed("base"))
    }

    @Test func overrideNeverDownloads() async throws {
        let d = ScriptedDownloader(payload: payload)
        let f = try await make(downloader: d)
        #expect(await f.port.startFirstRunDownload(isDataDirectoryOverridden: true) == nil)
        #expect(d.callCount == 0)
        #expect(await f.port.current().model == .none)
    }

    @Test func alreadyInstalledDoesNotDownload() async throws {
        let d = ScriptedDownloader(payload: payload)
        let f = try await make(downloader: d)
        _ = try await f.models.download("base") { _ in }
        #expect(d.callCount == 1)
        #expect(await f.port.startFirstRunDownload(isDataDirectoryOverridden: false) == nil)
        #expect(d.callCount == 1)
        #expect(await f.port.current().model == .installed("base"))
    }

    @Test func failedDownloadIsReportedAndRetried() async throws {
        let d = ScriptedDownloader(payload: payload, errors: [URLError(.notConnectedToInternet)])
        let f = try await make(downloader: d)
        var it = await f.port.updates().makeAsyncIterator()
        _ = await it.next()
        #expect(await f.port.startFirstRunDownload(isDataDirectoryOverridden: false) == "base")
        let first = await collect(&it, until: Self.isTerminal)
        #expect(first.last == .failed("base", reason: "ネットワークにつながりませんでした"))
        #expect(await f.port.current().model == .failed("base", reason: "ネットワークにつながりませんでした"))
        await f.port.retryModelDownload()
        let second = await collect(&it, until: Self.isTerminal)
        #expect(d.callCount == 2)
        #expect(second.last == .installed("base"))
        #expect(await f.port.current().model == .installed("base"))
    }

    @Test func failureReasons() {
        #expect(LiveReadinessPort.failureReason(URLError(.timedOut)) == "ネットワークにつながりませんでした")
        #expect(LiveReadinessPort.failureReason(ModelError.checksumMismatch) == "ダウンロードしたファイルが壊れていました")
        #expect(LiveReadinessPort.failureReason(ModelError.sizeMismatch(expected: 1, actual: 2)) == "ダウンロードしたファイルが壊れていました")
        #expect(LiveReadinessPort.failureReason(FakeError(message: "x")) == "ダウンロードが途中で止まりました")
    }

    @Test func redetectClaudeSavesFoundPath() async throws {
        let f = try await make(downloader: ScriptedDownloader(payload: payload), locate: { "/fake/claude" },
                               isExecutable: { $0 == "/fake/claude" }, configure: { $0.claudePath = nil })
        #expect(await f.port.redetectClaude() == .init(path: "/fake/claude", found: true))
        #expect(try await f.settings.load().claudePath == "/fake/claude")
    }

    @Test func redetectClaudeNotFoundKeepsSetting() async throws {
        let f = try await make(downloader: ScriptedDownloader(payload: payload), locate: { nil },
                               isExecutable: { $0 == "/old/claude" }, configure: { $0.claudePath = "/old/claude" })
        #expect(await f.port.redetectClaude() == .init(path: "/old/claude", found: true))
        #expect(try await f.settings.load().claudePath == "/old/claude")
    }

    @Test func installGuideOpensTheWebPage() async throws {
        let f = try await make(downloader: ScriptedDownloader(payload: payload))
        await f.port.installGuide()
        #expect(await f.opener.opened == [LiveReadinessPort.installGuideURL])
        #expect(LiveReadinessPort.installGuideURL.scheme == "https")
    }
}
