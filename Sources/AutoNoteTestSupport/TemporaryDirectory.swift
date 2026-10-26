import Foundation

public enum TemporaryDirectory {
    public static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "autonote-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
