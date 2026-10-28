import Foundation

/// Arguments of `autonote dev live-summary` (parsed in Core so tests can reach them; `autonote` is an executable target).
public struct DevLiveSummaryArguments: Equatable, Sendable {
    public static let usage = "usage: autonote dev live-summary <live.json> [--state <state.json>] [--claude]"

    public enum ParseError: Error, Equatable {
        case invalid(String)
    }

    public var live: URL
    public var state: URL?
    public var useClaude: Bool

    public init(live: URL, state: URL? = nil, useClaude: Bool = false) {
        self.live = live; self.state = state; self.useClaude = useClaude
    }

    /// Exactly one positional argument (the live transcript); `--state <file>` and `--claude` are optional.
    public static func parse(_ args: [String]) throws -> DevLiveSummaryArguments {
        var live: URL?
        var state: URL?
        var useClaude = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--claude": useClaude = true; index += 1
            case "--state":
                guard index + 1 < args.count else { throw ParseError.invalid("--state needs a value") }
                state = URL(filePath: args[index + 1]); index += 2
            default:
                guard !arg.hasPrefix("--") else { throw ParseError.invalid("unknown argument \(arg)") }
                guard live == nil else { throw ParseError.invalid("only one <live.json> is allowed") }
                live = URL(filePath: arg); index += 1
            }
        }
        guard let live else { throw ParseError.invalid("<live.json> is required") }
        return DevLiveSummaryArguments(live: live, state: state, useClaude: useClaude)
    }
}
