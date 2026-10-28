import AutoNoteCore
import AutoNoteTestSupport
import Foundation

/// Developer-only subcommands (`autonote dev ...`). Deliberately absent from the public usage text.
enum DevCommands {
    private static let renderFixtureUsage =
        "usage: autonote dev render-fixture --out <dir> [--fixtures <dir>] [--no-compare]"

    static func run(_ args: [String]) async -> Int32 {
        let rest = Array(args.dropFirst())
        switch args.first {
        case "render-fixture": return await renderFixture(rest)
        case "record": return await DevRecord.run(rest)
        case "import": return await DevImport.run(rest)
        case "auto-record": return await DevAutoRecord.run(rest)
        case "devices": return await DevDevices.run(rest)
        case "engines": return await DevEngines.run(rest)
        case "transcribe": return await DevTranscribe.run(rest)
        case "models": return await DevModels.run(rest)
        case "summarize": return await DevSummarize.run(rest)
        case "live-summary": return await DevLiveSummary.run(rest)
        default:
            return usageError([renderFixtureUsage, DevRecord.usage, DevImport.usage, DevAutoRecord.usage, DevDevices.usage,
                               DevEngines.usage, DevTranscribe.usage, DevModels.usage, DevSummarize.usage, DevLiveSummary.usage].joined(separator: "\n"))
        }
    }

    private static func renderFixture(_ args: [String]) async -> Int32 {
        var out: URL?
        var fixtures = FixtureLibrary.defaultDirectory
        var compare = true
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--out":
                guard index + 1 < args.count else { return usageError(renderFixtureUsage) }
                out = URL(filePath: args[index + 1]); index += 2
            case "--fixtures":
                guard index + 1 < args.count else { return usageError(renderFixtureUsage) }
                fixtures = URL(filePath: args[index + 1]); index += 2
            case "--no-compare":
                compare = false; index += 1
            default:
                return usageError(renderFixtureUsage)
            }
        }
        guard let out else { return usageError(renderFixtureUsage) }

        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let written = try await FixtureRenderer.render(fixtures: fixtures, into: out)
            guard compare else {
                for path in written { print(path) }
                return 0
            }
            let differing = try FixtureRenderer.compare(out, expected: fixtures.appending(path: "expected"))
            if differing.isEmpty {
                print("一致: \(written.count) ファイル")
                return 0
            }
            for path in differing { printError("差分: \(path)") }
            return 1
        } catch {
            printError("error: \(error)")
            return 1
        }
    }

    /// Parses `[--data <dir>]` (nothing else); without it, `AppPaths.resolve()`. nil on any other argument.
    static func dataPaths(_ args: [String]) -> AppPaths? {
        switch args.count {
        case 0: return AppPaths.resolve()
        case 2 where args[0] == "--data": return AppPaths(root: URL(filePath: args[1], directoryHint: .isDirectory))
        default: return nil
        }
    }

    static func usageError(_ message: String) -> Int32 {
        printError(message)
        return 2
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
