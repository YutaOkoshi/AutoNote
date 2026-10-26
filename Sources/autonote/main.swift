import AutoNoteCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

func write(_ text: String, to handle: FileHandle) {
    if !text.isEmpty { handle.write(Data(text.utf8)) }
}

if arguments.first == "dev" {
    exit(await DevCommands.run(Array(arguments.dropFirst())))
}

if arguments.isEmpty {
    write(CLIRenderer.usage, to: .standardError)
    exit(1)
}

let cwd = URL(filePath: FileManager.default.currentDirectoryPath)
let parsed: CLIParseResult
do {
    parsed = try CLIParser.parse(arguments, cwd: cwd)
} catch {
    let out = CLIRenderer.render(error)
    write(out.stderr, to: .standardError)
    exit(out.exitCode)
}

switch parsed {
case .version:
    print(AutoNoteVersion.current)
    exit(0)
case .help:
    write(CLIRenderer.usage, to: .standardOutput)
    exit(0)
case .dev(let rest):
    exit(await DevCommands.run(rest))
case .invocation(let inv):
    let env = ProcessInfo.processInfo.environment
    let client = SocketClient(
        socketURL: AppPaths.resolve(environment: env).socketFile,
        launcher: AppIdentity.isDataDirectoryOverridden(env) ? nil : OpenBundleLauncher())
    let out: CLIOutput
    do {
        let response = try await client.send(inv.command, args: inv.args, responseTimeout: .seconds(inv.responseTimeoutSeconds))
        out = CLIRenderer.render(response, for: inv)
    } catch {
        out = CLIRenderer.render(error, json: inv.json, timeoutSeconds: inv.responseTimeoutSeconds)
    }
    write(out.stdout, to: .standardOutput)
    write(out.stderr, to: .standardError)
    exit(out.exitCode)
}
