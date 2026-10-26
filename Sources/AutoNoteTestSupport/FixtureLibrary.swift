import Foundation

public enum FixtureLibrary {
    /// Repository-root `Tests/Fixtures`, resolved from this file's path
    /// (Sources/AutoNoteTestSupport/FixtureLibrary.swift -> three levels up).
    /// Bundle resources are not used: they are not found once copied into an .app.
    public static let defaultDirectory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Tests/Fixtures", directoryHint: .isDirectory)

    public static let timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo")!
}
