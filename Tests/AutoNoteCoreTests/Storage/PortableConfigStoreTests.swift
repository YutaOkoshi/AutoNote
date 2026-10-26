import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Test func syncCreatesDefaultsThenCopiesNewerVaultFile() async throws {
    let v = try TemporaryDirectory.make(); let p = AppPaths(root: try TemporaryDirectory.make()); let store = PortableConfigStore(paths: p, outputFolder: v)
    #expect(try await store.sync().createdDefaults == [.dictionary, .frontmatter, .devices])
    let f = v.appending(path: "_autonote/dictionary.md"); #expect(try String(contentsOf: f, encoding: .utf8).contains("## 用語"))
    try Data("## 用語\n- 新語\n".utf8).write(to: f)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.path)
    #expect(try await store.sync().toMirror == [.dictionary]); #expect(try Data(contentsOf: p.portableMirrorDirectory.appending(path: "dictionary.md")) == Data("## 用語\n- 新語\n".utf8))
    #expect(try await store.sync().toMirror == [])
}

@Test func editsWhileUnavailableArePushedBack() async throws {
    let v = try TemporaryDirectory.make().appending(path: "Meetings"); let p = AppPaths(root: try TemporaryDirectory.make()); let data = Data("[{\"name\":\"x\"}]\n".utf8)
    let offline = PortableConfigStore(paths: p, outputFolder: v)
    try await offline.write(.devices, data); #expect(try await offline.read(.devices) == data)
    try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    #expect(try await PortableConfigStore(paths: p, outputFolder: v).sync().toVault.contains(.devices))
    #expect(try Data(contentsOf: v.appending(path: "_autonote/devices.json")) == data)
}

@Test func doesNotCreateMissingOutputFolder() async throws {
    let v = try TemporaryDirectory.make().appending(path: "Volumes/Ext/Meetings")
    let r = try await PortableConfigStore(paths: AppPaths(root: try TemporaryDirectory.make()), outputFolder: v).sync()
    #expect(r.outputAvailable == false); #expect(!FileManager.default.fileExists(atPath: v.path))
}

@Test func newerMirrorOverwritesVaultAndTiesGoToVault() async throws {
    let v = try TemporaryDirectory.make(); let p = AppPaths(root: try TemporaryDirectory.make()); let store = PortableConfigStore(paths: p, outputFolder: v)
    _ = try await store.sync()
    let vf = v.appending(path: "_autonote/devices.json"); let mf = p.portableMirrorDirectory.appending(path: "devices.json")
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    try Data("[1]\n".utf8).write(to: mf); try Data("[2]\n".utf8).write(to: vf)
    try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(10)], ofItemAtPath: mf.path)
    try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: vf.path)
    let r = try await store.sync(); #expect(r.toVault == [.devices]); #expect(try Data(contentsOf: vf) == Data("[1]\n".utf8))
    #expect(try vf.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == base.addingTimeInterval(10))
    try Data("[3]\n".utf8).write(to: mf); try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: mf.path)
    try Data("[4]\n".utf8).write(to: vf); try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: vf.path)
    let t = try await store.sync(); #expect(t.toMirror == [.devices]); #expect(try Data(contentsOf: mf) == Data("[4]\n".utf8))
}

@Test func unavailableWritesDefaultsToMirrorAndWriteGoesToBothWhenAvailable() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make())
    let off = PortableConfigStore(paths: p, outputFolder: nil)
    #expect(await off.isOutputAvailable == false)
    let r = try await off.sync(); #expect(r.createdDefaults == [.dictionary, .frontmatter, .devices]); #expect(r.outputAvailable == false)
    #expect(try await off.read(.prompt) == nil)
    let v = try TemporaryDirectory.make(); let on = PortableConfigStore(paths: p, outputFolder: v)
    try await on.write(.prompt, Data("p\n".utf8))
    #expect(try Data(contentsOf: v.appending(path: "_autonote/prompt.md")) == Data("p\n".utf8))
    #expect(try Data(contentsOf: p.portableMirrorDirectory.appending(path: "prompt.md")) == Data("p\n".utf8))
    #expect(try await on.sync().toMirror.isEmpty)
}

// MARK: - Sync state (final review C1)

private func existingVault(_ files: [String: String], age: TimeInterval = -86_400) throws -> URL {
    let v = try TemporaryDirectory.make(); let dir = v.appending(path: "_autonote")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, text) in files {
        let f = dir.appending(path: name); try Data(text.utf8).write(to: f)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: f.path)
    }
    return v
}

@Test func offlineDefaultsNeverOverwriteAnExistingVault() async throws {
    let mine = "## 用語\n- 自分の用語\n"
    let v = try existingVault(["dictionary.md": mine, "devices.json": "[{\"name\":\"mine\"}]\n"])
    let p = AppPaths(root: try TemporaryDirectory.make())
    _ = try await PortableConfigStore(paths: p, outputFolder: nil).sync()
    let r = try await PortableConfigStore(paths: p, outputFolder: v).sync()
    #expect(try String(contentsOf: v.appending(path: "_autonote/dictionary.md"), encoding: .utf8) == mine)
    #expect(try String(contentsOf: v.appending(path: "_autonote/devices.json"), encoding: .utf8) == "[{\"name\":\"mine\"}]\n")
    #expect(r.toVault == [.frontmatter])
    #expect(r.toMirror == [.dictionary, .devices])
    #expect(try String(contentsOf: p.portableMirrorDirectory.appending(path: "dictionary.md"), encoding: .utf8) == mine)
}

@Test func switchingOutputFolderKeepsTheNewFoldersContent() async throws {
    let a = try existingVault(["dictionary.md": "## 用語\n- A\n"], age: 0)
    let b = try existingVault(["dictionary.md": "## 用語\n- B\n"])
    let p = AppPaths(root: try TemporaryDirectory.make())
    _ = try await PortableConfigStore(paths: p, outputFolder: a).sync()
    let r = try await PortableConfigStore(paths: p, outputFolder: b).sync()
    #expect(try String(contentsOf: b.appending(path: "_autonote/dictionary.md"), encoding: .utf8) == "## 用語\n- B\n")
    #expect(r.toMirror.contains(.dictionary)); #expect(!r.toVault.contains(.dictionary))
    #expect(try String(contentsOf: p.portableMirrorDirectory.appending(path: "dictionary.md"), encoding: .utf8) == "## 用語\n- B\n")
}

@Test func offlineWriteIsPushedToAnUnchangedVault() async throws {
    let v = try TemporaryDirectory.make().appending(path: "Meetings")
    try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    let p = AppPaths(root: try TemporaryDirectory.make())
    _ = try await PortableConfigStore(paths: p, outputFolder: v).sync()
    let vf = v.appending(path: "_autonote/dictionary.md")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: vf.path)
    let moved = v.deletingLastPathComponent().appending(path: "Unmounted")
    try FileManager.default.moveItem(at: v, to: moved)
    try await PortableConfigStore(paths: p, outputFolder: v).write(.dictionary, Data("## 用語\n- オフライン\n".utf8))
    try FileManager.default.moveItem(at: moved, to: v)
    let r = try await PortableConfigStore(paths: p, outputFolder: v).sync()
    #expect(r.toVault == [.dictionary])
    #expect(try String(contentsOf: vf, encoding: .utf8) == "## 用語\n- オフライン\n")
    #expect(try await PortableConfigStore(paths: p, outputFolder: v).sync() == PortableSyncReport(outputAvailable: true))
}

@Test func offlineWriteLosesToAVaultChangedLater() async throws {
    let v = try TemporaryDirectory.make().appending(path: "Meetings")
    try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    let p = AppPaths(root: try TemporaryDirectory.make())
    _ = try await PortableConfigStore(paths: p, outputFolder: v).sync()
    let moved = v.deletingLastPathComponent().appending(path: "Unmounted")
    try FileManager.default.moveItem(at: v, to: moved)
    try await PortableConfigStore(paths: p, outputFolder: v).write(.dictionary, Data("## 用語\n- オフライン\n".utf8))
    try FileManager.default.moveItem(at: moved, to: v)
    let vf = v.appending(path: "_autonote/dictionary.md")
    try Data("## 用語\n- 別の Mac\n".utf8).write(to: vf)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: vf.path)
    let r = try await PortableConfigStore(paths: p, outputFolder: v).sync()
    #expect(r.toMirror == [.dictionary])
    #expect(try String(contentsOf: vf, encoding: .utf8) == "## 用語\n- 別の Mac\n")
    #expect(try String(contentsOf: p.portableMirrorDirectory.appending(path: "dictionary.md"), encoding: .utf8) == "## 用語\n- 別の Mac\n")
}

@Test func syncStateIsWrittenWithSnakeCaseKeys() async throws {
    let v = try TemporaryDirectory.make(); let p = AppPaths(root: try TemporaryDirectory.make())
    _ = try await PortableConfigStore(paths: p, outputFolder: v).sync()
    let s = try String(contentsOf: p.portableMirrorDirectory.appending(path: ".sync-state.json"), encoding: .utf8)
    #expect(s.contains(#""output_folder" : "#)); #expect(s.contains(#""last_synced_sha256" : "#)); #expect(s.contains(#""dictionary.md" : "#))
}
