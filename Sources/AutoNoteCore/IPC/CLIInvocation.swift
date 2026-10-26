import Foundation

public struct CLIInvocation: Equatable, Sendable {
    public var command: IPCCommand
    public var args: IPCArgs
    public var json: Bool

    public init(command: IPCCommand, args: IPCArgs = IPCArgs(), json: Bool = false) {
        self.command = command
        self.args = args
        self.json = json
    }

    /// How long the CLI waits for the response line (X18): recording start/stop and import take longer.
    public var responseTimeoutSeconds: Int {
        switch command {
        case .start, .stop: 30
        case .import: 120
        default: 10
        }
    }
}

public enum CLIParseResult: Equatable, Sendable {
    case invocation(CLIInvocation)
    case version
    case help
    case dev([String])
}

public struct CLIUsageError: Error, Equatable {
    public var message: String

    public init(message: String) { self.message = message }
    public init(_ message: String) { self.message = message }
}

public enum CLIParser {
    public static func parse(_ argv: [String], cwd: URL) throws(CLIUsageError) -> CLIParseResult {
        guard let first = argv.first else { throw CLIUsageError("コマンドを指定してください") }
        switch first {
        case "--version": return .version
        case "--help", "-h", "help": return .help
        case "dev": return .dev(Array(argv.dropFirst()))
        default: break
        }
        let json = argv.contains("--json")
        var rest = argv.filter { $0 != "--json" }
        let name = rest.removeFirst()

        func make(_ command: IPCCommand, _ args: IPCArgs = IPCArgs()) -> CLIParseResult {
            .invocation(CLIInvocation(command: command, args: args, json: json))
        }
        func noArguments(_ command: IPCCommand) throws(CLIUsageError) -> CLIParseResult {
            guard rest.isEmpty else { throw CLIUsageError("\(name) に余分な引数があります: \(rest.joined(separator: " "))") }
            return make(command)
        }

        switch name {
        case "start":
            var args = IPCArgs()
            if !rest.isEmpty {
                guard rest.count == 2, rest[0] == "--lang", let lang = Language(rawValue: rest[1]) else {
                    throw CLIUsageError("start の引数が正しくありません（--lang auto|ja|en）")
                }
                args.lang = lang
            }
            return make(.start, args)
        case "stop": return try noArguments(.stop)
        case "pause": return try noArguments(.pause)
        case "resume": return try noArguments(.resume)
        case "status": return try noArguments(.status)
        case "bookmark":
            return make(.bookmark, rest.isEmpty ? IPCArgs() : IPCArgs(note: rest.joined(separator: " ")))
        case "list":
            if rest.isEmpty { return make(.list) }
            guard rest.count == 2, rest[0] == "--since" else { throw CLIUsageError("list の引数が正しくありません（--since YYYY-MM-DD）") }
            return make(.list, IPCArgs(since: rest[1]))
        case "latest":
            if rest.isEmpty { return make(.latest) }
            guard rest == ["--open"] else { throw CLIUsageError("latest の引数が正しくありません（--open）") }
            return make(.latest, IPCArgs(open: true))
        case "import":
            guard rest.count == 1 else { throw CLIUsageError("import にはファイルを 1 つ指定してください") }
            let url = rest[0].hasPrefix("/") ? URL(filePath: rest[0]) : cwd.appending(path: rest[0])
            return make(.import, IPCArgs(file: url.standardizedFileURL.path))
        case "regenerate":
            guard rest.count == 1 else { throw CLIUsageError("regenerate には会議 ID を 1 つ指定してください") }
            return make(.regenerate, IPCArgs(meetingID: rest[0]))
        case "automations":
            switch rest.first {
            case "list" where rest.count == 1: return make(.automationsList)
            case "run" where rest.count == 3: return make(.automationsRun, IPCArgs(meetingID: rest[2], name: rest[1]))
            default: throw CLIUsageError("automations list、または automations run <名前> <id> の形で指定してください")
            }
        default:
            throw CLIUsageError("知らないコマンドです: \(name)")
        }
    }
}
