import Foundation

/// Arguments of `autonote dev summarize` (parsed in Core so tests can reach them; `autonote` is an executable target).
public struct DevSummarizeArguments: Equatable, Sendable {
    public static let usage = """
        usage: autonote dev summarize --fake <transcript.json> --out <dir> [--minutes <minutes.json>] [--fail-summary] [--claude]
               [--minutes-out <path>]
               (--minutes is required unless --fail-summary or --claude is given;
                --minutes-out copies the generated minutes.json (MinutesOutput) to <path>)
        """

    public enum ParseError: Error, Equatable {
        case invalid(String)
    }

    public var transcript: URL
    public var out: URL
    public var minutes: URL?
    public var failSummary: Bool
    public var useClaude: Bool
    public var minutesOut: URL?

    public init(transcript: URL, out: URL, minutes: URL? = nil, failSummary: Bool = false, useClaude: Bool = false,
                minutesOut: URL? = nil) {
        self.transcript = transcript; self.out = out; self.minutes = minutes
        self.failSummary = failSummary; self.useClaude = useClaude; self.minutesOut = minutesOut
    }

    public static func parse(_ args: [String]) throws -> DevSummarizeArguments {
        var transcript: URL?
        var out: URL?
        var minutes: URL?
        var failSummary = false
        var useClaude = false
        var minutesOut: URL?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--fail-summary": failSummary = true; index += 1
            case "--claude": useClaude = true; index += 1
            case "--fake", "--out", "--minutes", "--minutes-out":
                guard index + 1 < args.count else { throw ParseError.invalid("\(arg) needs a value") }
                let url = URL(filePath: args[index + 1])
                switch arg {
                case "--fake": transcript = url
                case "--out": out = URL(filePath: args[index + 1], directoryHint: .isDirectory)
                case "--minutes-out": minutesOut = url
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
                                     failSummary: failSummary, useClaude: useClaude, minutesOut: minutesOut)
    }

    /// One track of the fictional meeting that `dev summarize --fake` builds.
    public struct FakeTrack: Equatable, Sendable {
        public var track: Track
        public var utterances: [Utterance]
        /// Where the (silent) segment is written, relative to the meeting directory.
        public var relativePath: String { "tracks/\(track.rawValue)-000.wav" }
        /// The file name the final transcription pass hands the transcriber (SegmentMerger's `merged/<track>-0.wav`).
        public var mergedFileName: String { "\(track.rawValue)-0.wav" }
    }

    /// Lays the `--fake` transcript out as tracks so the speakers survive TranscriptMerger, which names speakers by
    /// track (mic = me, system = other): utterances of `other` go to a system track, the rest (`me`, `unknown`) to the
    /// mic track. Without any `other` there is only the mic track, as before. Only the dev command uses this.
    public static func fakeTracks(_ utterances: [Utterance]) -> [FakeTrack] {
        let other = utterances.filter { $0.speaker == .other }
        let mic = FakeTrack(track: .mic, utterances: utterances.filter { $0.speaker != .other })
        return other.isEmpty ? [mic] : [mic, FakeTrack(track: .system, utterances: other)]
    }

    /// `--minutes-out`: copies the generated `minutes.json` to `destination` (creating its folder) after checking that
    /// it decodes as `MinutesOutput`, so an evaluation script gets the structured minutes, not the Markdown note.
    public static func exportMinutes(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        _ = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: data)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
}
