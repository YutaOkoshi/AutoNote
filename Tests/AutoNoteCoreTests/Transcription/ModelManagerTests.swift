import AutoNoteCore
import AutoNoteTestSupport
import CryptoKit
import Foundation
import Testing

@Suite struct ModelManagerTests {
    private func model(_ blob: Data) -> WhisperModel {
        WhisperModel(
            name: "fake", url: URL(string: "https://example.invalid/ggml-fake.bin")!,
            sizeBytes: Int64(blob.count),
            sha256: SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined())
    }

    private func contents(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
    }

    @Test func downloadVerifiesAndInstalls() async throws {
        let blob = Data("fake-model".utf8)
        let dir = try TemporaryDirectory.make()
        let mm = ModelManager(directory: dir, catalog: [model(blob)], downloader: FakeModelDownloader(payload: blob))
        let p = ProgressBox()
        let url = try await mm.download("fake") { p.append($0) }
        #expect(url.lastPathComponent == "ggml-fake.bin")
        #expect(await mm.installed().map(\.name) == ["fake"])
        #expect(await mm.fileURL(for: "fake") == url)
        #expect(try await mm.verify("fake"))
        #expect(p.values.last == 1.0)
        #expect(try contents(dir) == ["ggml-fake.bin"])
    }

    @Test func corruptDownloadIsRejectedAndLeavesNothing() async throws {
        let blob = Data("fake-model".utf8)
        var bad = blob
        bad[0] ^= 0xFF
        let dir = try TemporaryDirectory.make()
        let mm = ModelManager(directory: dir, catalog: [model(blob)], downloader: FakeModelDownloader(payload: bad))
        await #expect(throws: ModelError.checksumMismatch) { try await mm.download("fake") { _ in } }
        #expect(try contents(dir).isEmpty)
        #expect(await mm.installed().isEmpty)
    }

    @Test func wrongSizeDownloadIsRejectedAndLeavesNothing() async throws {
        let blob = Data("fake-model".utf8)
        let dir = try TemporaryDirectory.make()
        let mm = ModelManager(
            directory: dir, catalog: [model(blob)],
            downloader: FakeModelDownloader(payload: blob + Data([1])))
        await #expect(throws: ModelError.sizeMismatch(expected: Int64(blob.count), actual: Int64(blob.count + 1))) {
            try await mm.download("fake") { _ in }
        }
        #expect(try contents(dir).isEmpty)
    }

    @Test func interruptedDownloadLeavesNothing() async throws {
        let blob = Data("fake-model".utf8)
        let dir = try TemporaryDirectory.make()
        let mm = ModelManager(
            directory: dir, catalog: [model(blob)],
            downloader: FakeModelDownloader(payload: blob, failAfterBytes: 3))
        await #expect(throws: (any Error).self) { try await mm.download("fake") { _ in } }
        #expect(try contents(dir).isEmpty)
        #expect(await mm.installed().isEmpty)
    }

    @Test func unknownModelThrows() async throws {
        let mm = ModelManager(
            directory: try TemporaryDirectory.make(), catalog: [],
            downloader: FakeModelDownloader(payload: Data()))
        await #expect(throws: ModelError.unknownModel("nope")) { try await mm.download("nope") { _ in } }
    }

    @Test func wrongSizeFileIsNotInstalled() async throws {
        let blob = Data("fake-model".utf8)
        let dir = try TemporaryDirectory.make()
        try Data("short".utf8).write(to: dir.appending(path: "ggml-fake.bin"))
        let mm = ModelManager(directory: dir, catalog: [model(blob)], downloader: FakeModelDownloader(payload: blob))
        #expect(await mm.installed().isEmpty)
        #expect(await mm.fileURL(for: "fake") == nil)
        #expect(try await mm.verify("fake") == false)
    }

    @Test func deleteRemovesFile() async throws {
        let blob = Data("fake-model".utf8)
        let dir = try TemporaryDirectory.make()
        let mm = ModelManager(directory: dir, catalog: [model(blob)], downloader: FakeModelDownloader(payload: blob))
        _ = try await mm.download("fake") { _ in }
        try await mm.delete("fake")
        #expect(await mm.installed().isEmpty)
        #expect(try contents(dir).isEmpty)
        try await mm.delete("fake")  // already gone: no error
    }

    @Test func concurrentDownloadsShareOne() async throws {
        let blob = Data("fake-model".utf8)
        let fake = FakeModelDownloader(payload: blob, delay: .milliseconds(200))
        let mm = ModelManager(directory: try TemporaryDirectory.make(), catalog: [model(blob)], downloader: fake)
        async let a = mm.download("fake") { _ in }
        try await waitUntil { fake.callCount == 1 }
        async let b = mm.download("fake") { _ in }
        let (ua, ub) = try await (a, b)
        #expect(ua == ub)
        #expect(fake.callCount == 1)
    }

    @Test func catalogHasDefaults() {
        #expect(Set(WhisperModelCatalog.all.map(\.name)) == ["base", "small", "large-v3-turbo", "large-v3-turbo-q5_0"])
        #expect(WhisperModelCatalog.all.allSatisfy { $0.url.host() == "huggingface.co" && $0.sha256.count == 64 })
        #expect(WhisperModelCatalog.all.allSatisfy { $0.url.lastPathComponent == $0.fileName })
    }
}
