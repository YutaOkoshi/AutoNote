import AutoNoteCore
import Foundation

/// `autonote dev update` — the updater, for development and E2E.
///   --status   the running app's updater status, one JSON line (socket `update.status`)
///   --now      「今すぐ確認」 in the running app (socket `update.check`), then its status
///   --check    in this process: read the feed, and when newer, download and verify into a temporary folder
///              (nothing is installed). `--feed <url>` (debug builds only) replaces the feed; `--app <path>` is the
///              app whose signature the download must match (default: the .app this CLI is in).
/// Exit codes: 0 done (also "up to date"), 1 error or refused update, 2 usage.
enum DevUpdate {
    static let usage = "usage: autonote dev update --status | --now | --check [--feed <url>] [--app <path>]"

    static func run(_ args: [String]) async -> Int32 {
        switch args.first {
        case "--status": return args.count == 1 ? await socket(.updateStatus) : DevCommands.usageError(usage)
        case "--now": return args.count == 1 ? await socket(.updateCheck) : DevCommands.usageError(usage)
        case "--check": return await check(Array(args.dropFirst()))
        default: return DevCommands.usageError(usage)
        }
    }

    private static func socket(_ cmd: IPCCommand) async -> Int32 {
        let client = SocketClient(socketURL: AppPaths.resolve().socketFile, launcher: nil)
        do {
            let response = try await client.send(cmd, args: IPCArgs(), responseTimeout: .seconds(120))
            guard response.ok, let update = response.result?.update else {
                DevCommands.printError("error: \(response.error?.message ?? "応答に update がありません")")
                return 1
            }
            print(line(update))
            return 0
        } catch {
            DevCommands.printError("error: \(CLIRenderer.render(error, json: false).stderr)")
            return 1
        }
    }

    private struct CheckLine: Encodable {
        var state: String
        var current: String
        var latest: String?
        var message: String?
        var app: String?
    }

    private static func check(_ args: [String]) async -> Int32 {
        var feed: URL?
        var app = BundleFacts.enclosingApp(ofExecutable: URL(filePath: CommandLine.arguments[0]))
        var i = 0
        while i < args.count {
            guard i + 1 < args.count else { return DevCommands.usageError(usage) }
            switch args[i] {
            case "--feed":
                guard UpdateContext.isDebugBuild else {
                    DevCommands.printError("error: --feed は開発用のビルド（debug）でだけ使えます")
                    return 2
                }
                feed = URL(string: args[i + 1])
            case "--app": app = URL(filePath: args[i + 1], directoryHint: .isDirectory)
            default: return DevCommands.usageError(usage)
            }
            i += 2
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "autonote-dev-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let current = UpdateContext.currentVersion(runningApp: app)
        let checker = UpdateChecker(context: UpdateContext(
            feedURL: feed ?? UpdateURLPolicy.thisRepository.feedURL!, policy: feed == nil ? .thisRepository : .development,
            currentVersion: current, bundleID: AppIdentity.bundleID, runningApp: app, directory: work))
        do {
            switch try await checker.check() {
            case .upToDate(let latest):
                print(line(CheckLine(state: "up_to_date", current: current.description, latest: latest.description)))
                return 0
            case .available(let release):
                let staged = try await checker.prepare(release)
                print(line(CheckLine(state: "verified", current: current.description, latest: release.version.description,
                                     message: "署名・SHA-256・版・bundle identifier を確かめました（入れ替えはしません）",
                                     app: staged.app.lastPathComponent)))
                return 0
            }
        } catch {
            print(line(CheckLine(state: "refused", current: current.description, message: error.message)))
            return 1
        }
    }

    private static func line(_ value: some Encodable) -> String {
        String(decoding: (try? AutoNoteJSON.compactEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
