import Testing
import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

private struct Fixture {
    let home: URL
    let paths: AppPaths
    let store: SettingsStore
    init() throws {
        home = try TemporaryDirectory.make()
        paths = AppPaths(root: try TemporaryDirectory.make())
        try paths.createBaseDirectories()
        store = SettingsStore(paths: paths)
    }
    var defaultFolder: URL { home.appending(path: "Documents/AutoNote") }
    var defaultPath: String { defaultFolder.path(percentEncoded: false) }
}

private struct Boom: Error {}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

@Test func nilBecomesDocumentsAutoNote() async throws {
    let f = try Fixture()
    let outcome = await FirstRunDefaults.apply(settings: f.store, paths: f.paths, isDataDirectoryOverridden: false, home: f.home)
    #expect(outcome == .created(f.defaultPath))
    #expect(exists(f.defaultFolder))
    #expect(try await f.store.load().outputFolder == f.defaultPath)
}

@Test func emptyStringIsTreatedAsUnset() async throws {
    let f = try Fixture()
    try await f.store.update { $0.outputFolder = "" }
    let outcome = await FirstRunDefaults.apply(settings: f.store, paths: f.paths, isDataDirectoryOverridden: false, home: f.home)
    #expect(outcome == .created(f.defaultPath))
    #expect(try await f.store.load().outputFolder == f.defaultPath)
}

@Test func overrideUsesDataDirVault() async throws {
    let f = try Fixture()
    let vault = f.paths.root.appending(path: "vault").path(percentEncoded: false)
    let outcome = await FirstRunDefaults.apply(settings: f.store, paths: f.paths, isDataDirectoryOverridden: true, home: f.home)
    #expect(outcome == .created(vault))
    #expect(!vault.hasSuffix("/"))
    #expect(!exists(f.home.appending(path: "Documents")))
    #expect(try await f.store.load().outputFolder == vault)
}

@Test func existingFolderIsUnchanged() async throws {
    let f = try Fixture()
    try await f.store.update { $0.outputFolder = "/x/y" }
    let calls = Mutex(0)
    let outcome = await FirstRunDefaults.apply(settings: f.store, paths: f.paths, isDataDirectoryOverridden: false, home: f.home,
                                               createDirectory: { _ in calls.withLock { $0 += 1 } })
    #expect(outcome == .unchanged)
    #expect(calls.withLock { $0 } == 0)
    #expect(try await f.store.load().outputFolder == "/x/y")
}

@Test func creationFailureLeavesNil() async throws {
    let f = try Fixture()
    let outcome = await FirstRunDefaults.apply(settings: f.store, paths: f.paths, isDataDirectoryOverridden: false, home: f.home,
                                               createDirectory: { _ in throw Boom() })
    #expect(outcome == .failed)
    #expect(try await f.store.load().outputFolder == nil)
}

@Test func defaultPathOccupiedByFileLeavesNil() async throws {
    let f = try Fixture()
    try FileManager.default.createDirectory(at: f.defaultFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: f.defaultFolder)
    let outcome = await FirstRunDefaults.apply(settings: f.store, paths: f.paths, isDataDirectoryOverridden: false, home: f.home)
    #expect(outcome == .failed)
    #expect(try await f.store.load().outputFolder == nil)
}

@Test func existingDefaultDirectoryIsReused() async throws {
    let f = try Fixture()
    try FileManager.default.createDirectory(at: f.defaultFolder, withIntermediateDirectories: true)
    let outcome = await FirstRunDefaults.apply(settings: f.store, paths: f.paths, isDataDirectoryOverridden: false, home: f.home)
    #expect(outcome == .created(f.defaultPath))
}

@Test func blankInputMapsToDefault() throws {
    let f = try Fixture()
    #expect(FirstRunDefaults.outputFolder(forInput: "  ", paths: f.paths, isDataDirectoryOverridden: false, home: f.home) == f.defaultPath)
    #expect(FirstRunDefaults.outputFolder(forInput: "/a/b ", paths: f.paths, isDataDirectoryOverridden: false, home: f.home) == "/a/b")
}

@Test func tildeExpandsToHome() throws {
    let f = try Fixture()
    let home = f.home.path(percentEncoded: false).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    #expect(FirstRunDefaults.outputFolder(forInput: "~/Documents/AutoNote", paths: f.paths, isDataDirectoryOverridden: false, home: f.home) == f.defaultPath)
    #expect(FirstRunDefaults.outputFolder(forInput: "~/Documents/AutoNote/", paths: f.paths, isDataDirectoryOverridden: false, home: f.home) == f.defaultPath)
    #expect(f.defaultPath == home + "/Documents/AutoNote")
    #expect(FirstRunDefaults.outputFolder(forInput: "~", paths: f.paths, isDataDirectoryOverridden: false, home: f.home) == home)
}

@Test func trailingSlashIsStripped() throws {
    let f = try Fixture()
    #expect(FirstRunDefaults.outputFolder(forInput: "/a/b/", paths: f.paths, isDataDirectoryOverridden: false, home: f.home) == "/a/b")
    #expect(FirstRunDefaults.outputFolder(forInput: "/", paths: f.paths, isDataDirectoryOverridden: false, home: f.home) == "/")
}

@Test func modelToDownload() {
    #expect(FirstRunDefaults.modelToDownload(installed: [], isDataDirectoryOverridden: false) == "base")
    #expect(FirstRunDefaults.modelToDownload(installed: ["small"], isDataDirectoryOverridden: false) == nil)
    #expect(FirstRunDefaults.modelToDownload(installed: [], isDataDirectoryOverridden: true) == nil)
}
