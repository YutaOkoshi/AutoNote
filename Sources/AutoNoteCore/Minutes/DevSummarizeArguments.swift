import Foundation

/// Arguments of `autonote dev summarize` (parsed in Core so tests can reach them; `autonote` is an executable target).
public struct DevSummarizeArguments: Equatable, Sendable {
    public static let usage = """
        usage: autonote dev summarize --fake <transcript.json> --out <dir> [--minutes <minutes.json>] [--fail-summary] [--claude]
               (--minutes is required unless --fail-summary or --claude is given)
        """

    public enum ParseError: Error, Equatable {
        case invalid(String)
    }

    public var transcript: URL
    public var out: URL
    public var minutes: URL?
    public var failSummary: Bool
    public var useClaude: Bool

    public init(transcript: URL, out: URL, minutes: URL? = nil, failSummary: Bool = false, useClaude: Bool = false) {
        self.transcript = transcript; self.out = out; self.minutes = minutes
        self.failSummary = failSummary; self.useClaude = useClaude
    }

    public static func parse(_ args: [String]) throws -> DevSummarizeArguments {
        var transcript: URL?
        var out: URL?
        var minutes: URL?
        var failSummary = false
        var useClaude = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--fail-summary": failSummary = true; index += 1
            case "--claude": useClaude = true; index += 1
            case "--fake", "--out", "--minutes":
                guard index + 1 < args.count else { throw ParseError.invalid("\(arg) needs a value") }
                let url = URL(filePath: args[index + 1])
                switch arg {
                case "--fake": transcript = url
                case "--out": out = URL(filePath: args[index + 1], directoryHint: .isDirectory)
                default: minutes = url
                }
                index += 2
            default:
                throw ParseError.invalid("unknown argument \(arg)")
            }
        }
        guard let transcript else { throw ParseError.invalid("--fake is required") }
        guard let out else { throw ParseError.invalid("--out is required") }
        guard minutes != nil || failSummary || useClaude else {
            throw ParseError.invalid("--minutes is required unless --fail-summary or --claude is given")
        }
        return DevSummarizeArguments(transcript: transcript, out: out, minutes: minutes,
                                     failSummary: failSummary, useClaude: useClaude)
    }
}
