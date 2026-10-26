import AutoNoteCore
import Foundation
import Synchronization

/// `autonote dev models list|download <name>|delete <name> [--data <dir>]` — the whisper models under
/// `<data>/models` (default `AppPaths.resolve()`). `list` prints a JSON array; `download` reports progress on stderr
/// and prints the installed path.
enum DevModels {
    static let usage = "usage: autonote dev models list|download <name>|delete <name> [--data <dir>]"

    private struct Entry: Encodable {
        var name: String
        var installed: Bool
        var sizeBytes: Int64
        var path: String
    }

    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else { return DevCommands.usageError(usage) }
        var rest = Array(args.dropFirst())
        var name: String?
        if command != "list" {
            guard let first = rest.first, !first.hasPrefix("--") else { return DevCommands.usageError(usage) }
            name = first
            rest.removeFirst()
        }
        guard let paths = DevCommands.dataPaths(rest) else { return DevCommands.usageError(usage) }
        let directory = paths.modelsDirectory
        let manager = ModelManager(directory: directory)
        do {
            switch (command, name) {
            case ("list", _):
                let installed = Set(await manager.installed().map(\.name))
                let entries = WhisperModelCatalog.all.map {
                    Entry(name: $0.name, installed: installed.contains($0.name), sizeBytes: $0.sizeBytes,
                          path: directory.appending(path: $0.fileName).path)
                }
                print(String(decoding: try AutoNoteJSON.encoder().encode(entries), as: UTF8.self))
            case ("download", let name?):
                let reporter = ProgressReporter(name: name)
                let url = try await manager.download(name) { reporter.report($0) }
                print(url.path)
            case ("delete", let name?):
                try await manager.delete(name)
            default:
                return DevCommands.usageError(usage)
            }
            return 0
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }
}

/// Writes `download <name>: N%` to stderr each time the whole percent changes.
private final class ProgressReporter: Sendable {
    private let name: String
    private let last = Mutex(-1)

    init(name: String) { self.name = name }

    func report(_ value: Double) {
        let percent = Int(value * 100)
        guard last.withLock({ old in
            guard percent > old else { return false }
            old = percent
            return true
        }) else { return }
        DevCommands.printError("download \(name): \(percent)%")
    }
}
