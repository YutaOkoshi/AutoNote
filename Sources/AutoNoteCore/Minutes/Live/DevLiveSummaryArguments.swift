import Foundation

/// Arguments of `autonote dev live-summary` (parsed in Core so tests can reach them; `autonote` is an executable target).
public struct DevLiveSummaryArguments: Equatable, Sendable {
    public static let usage = "usage: autonote dev live-summary <live.json> [--state <state.json>] [--questions <questions.json>] [--claude]"

    public enum ParseError: Error, Equatable {
        case invalid(String)
    }

    public var live: URL
    public var state: URL?
    /// A questions file (`LiveQuestionList`); its undecided items are sent with the call.
    public var questions: URL?
    public var useClaude: Bool

    public init(live: URL, state: URL? = nil, questions: URL? = nil, useClaude: Bool = false) {
        self.live = live; self.state = state; self.questions = questions; self.useClaude = useClaude
    }

    /// Exactly one positional argument (the live transcript); `--state <file>`, `--questions <file>` and `--claude` are optional.
    public static func parse(_ args: [String]) throws -> DevLiveSummaryArguments {
        var live: URL?
        var state: URL?
        var questions: URL?
        var useClaude = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--claude": useClaude = true; index += 1
            case "--state":
                guard index + 1 < args.count else { throw ParseError.invalid("--state needs a value") }
                state = URL(filePath: args[index + 1]); index += 2
            case "--questions":
                guard index + 1 < args.count else { throw ParseError.invalid("--questions needs a value") }
                questions = URL(filePath: args[index + 1]); index += 2
            default:
                guard !arg.hasPrefix("--") else { throw ParseError.invalid("unknown argument \(arg)") }
                guard live == nil else { throw ParseError.invalid("only one <live.json> is allowed") }
                live = URL(filePath: arg); index += 1
            }
        }
        guard let live else { throw ParseError.invalid("<live.json> is required") }
        return DevLiveSummaryArguments(live: live, state: state, questions: questions, useClaude: useClaude)
    }
}

/// The one JSON line `autonote dev live-summary` prints: the state's keys, plus (with `--questions`) the ids sent,
/// the ids found asked, and the questions after the marks (a questions file again).
public struct DevLiveSummaryLine: Encodable, Sendable {
    public var state: LiveSummaryState
    public var sentQuestionIDs: [String]?
    public var askedQuestionIDs: [String]?
    public var questions: LiveQuestionList?

    public init(state: LiveSummaryState, sentQuestionIDs: [String]? = nil, askedQuestionIDs: [String]? = nil,
                questions: LiveQuestionList? = nil) {
        self.state = state; self.sentQuestionIDs = sentQuestionIDs; self.askedQuestionIDs = askedQuestionIDs
        self.questions = questions
    }

    private enum CodingKeys: String, CodingKey {
        case sentQuestionIDs = "sentQuestionIds", askedQuestionIDs = "askedQuestionIds", questions
    }

    public func encode(to encoder: any Encoder) throws {
        try state.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sentQuestionIDs, forKey: .sentQuestionIDs)
        try c.encodeIfPresent(askedQuestionIDs, forKey: .askedQuestionIDs)
        try c.encodeIfPresent(questions, forKey: .questions)
    }

    public func encoded() throws -> Data { try AutoNoteJSON.compactEncoder().encode(self) }
}
