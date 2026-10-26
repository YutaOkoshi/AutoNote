import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Test func manifestSaveLoadUpdateDelete() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); let store = ManifestStore(paths: p); let id = Samples.manifest.id
    try await store.save(Samples.manifest)
    let m = try await store.update(id) { $0.status = .recording }
    #expect(try await store.load(id) == m); #expect(await store.unfinishedRecordings().map(\.id) == [id])
    try await store.delete(id); #expect(!FileManager.default.fileExists(atPath: p.meetingDirectory(id).path))
    let r = AppPaths(root: URL(filePath: "/r"))
    #expect(r.manifestFile(id).path == "/r/recordings/20261024-1400-a1b2/manifest.json"); #expect(r.transcriptFile(id, .raw).path == "/r/transcripts/20261024-1400-a1b2/raw.json")
    #expect(r.vaultStateFile(id).path == "/r/vault-state/20261024-1400-a1b2.json"); #expect(r.modelsDirectory.path == "/r/models")
    #expect(AppPaths.resolve(environment: ["AUTONOTE_DATA_DIR": "/tmp/e2e"]).root.path == "/tmp/e2e"); #expect(AppPaths.resolve(environment: [:]) == .standard)
    #expect(AppPaths.resolve(environment: ["AUTONOTE_DATA_DIR": ""]) == .standard)
}

@Test func deleteRemovesTranscriptsAndVaultState() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); let store = ManifestStore(paths: p); let id = Samples.manifest.id
    try await store.save(Samples.manifest)
    try p.createBaseDirectories()
    try FileManager.default.createDirectory(at: p.transcriptsDirectory(id), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: p.minutesFile(id)); try Data("{}".utf8).write(to: p.vaultStateFile(id))
    try await store.delete(id)
    for url in [p.meetingDirectory(id), p.transcriptsDirectory(id), p.vaultStateFile(id)] {
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Test func allSkipsCorruptManifest() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); let store = ManifestStore(paths: p); try await store.save(Samples.manifest)
    let broken = p.meetingDirectory(MeetingID(rawValue: "20261024-0900-ffff"))
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: broken.appending(path: "manifest.json"))
    #expect(await store.all().map(\.id) == [Samples.manifest.id])
}

@Test func allIsNewestFirst() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); let store = ManifestStore(paths: p)
    var older = Samples.manifest; older.id = MeetingID(rawValue: "20261023-1000-0001"); older.startedAt = Samples.start.addingTimeInterval(-86400)
    try await store.save(older); try await store.save(Samples.manifest)
    #expect(await store.all().map(\.id) == [Samples.manifest.id, older.id])
}

@Test func manifestSaveLoadKeepsSubSecondDates() async throws {
    let store = ManifestStore(paths: AppPaths(root: try TemporaryDirectory.make()))
    // JSON keeps milliseconds, so take the current time at millisecond precision.
    let ms = (Date().timeIntervalSince1970 * 1000).rounded(.down)
    var m = Samples.manifest
    m.startedAt = Date(timeIntervalSince1970: ms / 1000); m.endedAt = Date(timeIntervalSince1970: (ms + 12_345) / 1000)
    try await store.save(m)
    #expect(try await store.load(m.id) == m)
}
