import AutoNoteCore
import Foundation

/// `autonote dev import <file> --out <dir> [--lang auto|ja|en] [--start <ISO8601>]`
enum DevImport {
    static let usage = "usage: autonote dev import <file> --out <dir> [--lang auto|ja|en] [--start <ISO8601>]"

    private struct Output: Encodable {
        var meetingId: String
        var manifest: String
        var wav: String
        var seconds: Double
    }

    static func run(_ args: [String]) async -> Int32 {
        var file: URL?
        var out: URL?
        var language = Language.ja
        var start: Date?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--out":
                guard index + 1 < args.count else { return DevCommands.usageError(usage) }
                out = URL(filePath: args[index + 1], directoryHint: .isDirectory); index += 2
            case "--lang":
                guard index + 1 < args.count, let l = Language(rawValue: args[index + 1]) else { return DevCommands.usageError(usage) }
                language = l; index += 2
            case "--start":
                guard index + 1 < args.count, let d = parseDate(args[index + 1]) else { return DevCommands.usageError(usage) }
                start = d; index += 2
            default:
                guard file == nil, !args[index].hasPrefix("--") else { return DevCommands.usageError(usage) }
                file = URL(filePath: args[index]); index += 1
            }
        }
        guard let file, let out else { return DevCommands.usageError(usage) }

        do {
            let paths = AppPaths(root: out)
            let importer = AudioImporter(paths: paths, manifests: ManifestStore(paths: paths))
            let manifest = try await importer.importFile(file, startedAt: start, language: language)
            guard let track = manifest.tracks.first else { throw ImportError.noAudioTrack }
            let output = Output(meetingId: manifest.id.rawValue, manifest: paths.manifestFile(manifest.id).path,
                                wav: paths.meetingDirectory(manifest.id).appending(path: track.relativePath).path,
                                seconds: track.durationSeconds ?? 0)
            print(String(decoding: try AutoNoteJSON.compactEncoder().encode(output), as: UTF8.self))
            return 0
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}
