import Foundation
import AutoNoteCore

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

public struct FixtureMeeting: Sendable {
    public var manifest: Manifest
    public var parts: [TrackTranscription]
    public var minutes: MinutesOutput?

    public init(manifest: Manifest, parts: [TrackTranscription], minutes: MinutesOutput?) {
        self.manifest = manifest; self.parts = parts; self.minutes = minutes
    }
}

extension FixtureLibrary {
    public static let engine = "whisper.cpp large-v3-turbo"

    /// `meetings/*/` in name order. Each track file pairs with `utterances/<file name without extension>.json`;
    /// `minutes.json` is optional.
    public static func meetings(in directory: URL = defaultDirectory) throws -> [FixtureMeeting] {
        let fm = FileManager.default
        let root = directory.appending(path: "meetings", directoryHint: .isDirectory)
        let names = try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted()
        let decoder = AutoNoteJSON.decoder()
        var result: [FixtureMeeting] = []
        for name in names {
            let dir = root.appending(path: name, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: dir.appending(path: "manifest.json")))
            let parts = try manifest.tracks.map { file -> TrackTranscription in
                let stem = URL(filePath: file.relativePath).deletingPathExtension().lastPathComponent
                let data = try Data(contentsOf: dir.appending(path: "utterances/\(stem).json"))
                return TrackTranscription(file: file, utterances: try decoder.decode([Utterance].self, from: data))
            }
            let minutesURL = dir.appending(path: "minutes.json")
            let minutes = fm.fileExists(atPath: minutesURL.path)
                ? try decoder.decode(MinutesOutput.self, from: Data(contentsOf: minutesURL)) : nil
            result.append(FixtureMeeting(manifest: manifest, parts: parts, minutes: minutes))
        }
        return result
    }

    public static func dictionary(in directory: URL = defaultDirectory) throws -> DictionaryFile {
        let text = try String(contentsOf: directory.appending(path: "dictionary.md"), encoding: .utf8)
        return DictionaryFile.parse(text).dictionary
    }
}
