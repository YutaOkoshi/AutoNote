import Foundation
import Testing
import AutoNoteTestSupport

@Test func fixtureDirectoryExists() {
    #expect(FileManager.default.fileExists(atPath: FixtureLibrary.defaultDirectory.appending(path: "README.md").path))
}

@Test func temporaryDirectoryIsCreated() throws {
    let url = try TemporaryDirectory.make()
    defer { try? FileManager.default.removeItem(at: url) }
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
    #expect(url.lastPathComponent.hasPrefix("autonote-tests-"))
}
