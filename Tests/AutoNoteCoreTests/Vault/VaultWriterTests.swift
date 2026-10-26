import Testing
import Foundation
import AutoNoteTestSupport
@testable import AutoNoteCore

private func doc(status: MeetingStatus = .minutesGenerated, minutes: MinutesOutput? = Samples.minutes, title: String? = nil, id: String = "20261024-1400-a1b2") -> MeetingDocument {
    var m = Samples.manifest; m.status = status; m.title = title; m.id = .init(rawValue: id)
    return MeetingDocument(manifest: m, transcript: Transcript(utterances: [u(5, .me, "a")], engine: "e", language: .ja), minutes: minutes,
                           frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.1.0", timeZone: Samples.tokyo)
}
private func writer() throws -> VaultWriter { VaultWriter(outputFolder: try TemporaryDirectory.make(), paths: AppPaths(root: try TemporaryDirectory.make())) }
private func url(_ o: VaultWriteOutcome) throws -> URL { guard case .written(let x) = o else { throw FakeError(message: "\(o)") }; return x }
@Test func writesOverwritesRewritesAndSuffixes() async throws {
    let w = try writer(); let first = try url(await w.write(doc()))
    #expect(first.path.hasSuffix("/2026/2026-10-24_1400_プロジェクト定例.md")); #expect(await w.record(for: Samples.manifest.id)?.relativePath == "2026/2026-10-24_1400_プロジェクト定例.md")
    #expect(try await w.write(doc()) == .written(first))
    try FileManager.default.removeItem(at: first); #expect(try await w.write(doc()) == .written(first))   // 利用者が消したら書き直す
    #expect(try url(await w.write(doc(id: "20261024-1400-ffff"))).lastPathComponent == "2026-10-24_1400_プロジェクト定例-2.md")
}
@Test func detectsExternalEditAndUnknownOrigin() async throws {
    let v = try TemporaryDirectory.make(); let w = VaultWriter(outputFolder: v, paths: AppPaths(root: try TemporaryDirectory.make()))
    let f = try url(await w.write(doc()))
    try (try String(contentsOf: f, encoding: .utf8) + "利用者のメモ\n").write(to: f, atomically: true, encoding: .utf8)
    #expect(try await w.write(doc()) == .conflict(f)); #expect(try String(contentsOf: f, encoding: .utf8).hasSuffix("利用者のメモ\n"))
    #expect(try await w.write(doc(), policy: .force) == .written(f))
    let otherMac = VaultWriter(outputFolder: v, paths: AppPaths(root: try TemporaryDirectory.make()))
    #expect(try await otherMac.write(doc()) == .conflict(f))
}
@Test func untitledIsRenamedWhenTitleArrives() async throws {
    let w = try writer(); let first = try url(await w.write(doc(status: .transcriptOnly, minutes: nil)))
    #expect(first.lastPathComponent == "2026-10-24_140000.md"); #expect(try url(await w.write(doc())).lastPathComponent == "2026-10-24_1400_プロジェクト定例.md")
    #expect(!FileManager.default.fileExists(atPath: first.path))
}
@Test func titledFileIsNotRenamedUnlessAsked() async throws {
    let w = try writer(); let f = try url(await w.write(doc()))
    #expect(try await w.write(doc(title: "改名後")) == .written(f)); #expect(try String(contentsOf: f, encoding: .utf8).contains("\n# 改名後\n"))
    #expect(try url(await w.write(doc(title: "改名後"), renameToMatchTitle: true)).lastPathComponent == "2026-10-24_1400_改名後.md")
    #expect(!FileManager.default.fileExists(atPath: f.path))
}
@Test func unavailableOutputFolderThrowsAndCreatesNothing() async throws {
    let missing = try TemporaryDirectory.make().appending(path: "Volumes/Ext/Meetings")
    let w = VaultWriter(outputFolder: missing, paths: AppPaths(root: try TemporaryDirectory.make()))
    await #expect(throws: VaultError.outputFolderUnavailable(missing)) { try await w.write(doc()) }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}
@Test func rebuildIndexAndRemove() async throws {
    let w = try writer(); _ = try await w.write(doc())
    let index = try await w.rebuildIndex()
    #expect(try String(contentsOf: index, encoding: .utf8).contains("[[2026/2026-10-24_1400_プロジェクト定例]]"))
    try await w.remove(Samples.manifest.id); _ = try await w.rebuildIndex()
    #expect(!(try String(contentsOf: index, encoding: .utf8)).contains("プロジェクト定例]]")); #expect(await w.record(for: Samples.manifest.id) == nil)
}
