import AutoNoteCore
import AutoNoteTestSupport
import Foundation

/// `autonote dev live-summary` — one live summary update over a live transcript, starting from `--state` (or the
/// empty state) with the undecided items of `--questions`. Uses the deterministic `FakeLiveSummarizer` unless
/// `--claude` is given. Prints the new state as one JSON line (the previous one unchanged when nothing is new); with
/// `--questions` the line also has `sent_question_ids`, `asked_question_ids` and the updated `questions`.
/// Exit codes: 0 done, 1 error, 2 usage.
enum DevLiveSummary {
    static let usage = DevLiveSummaryArguments.usage

    static func run(_ args: [String]) async -> Int32 {
        let options: DevLiveSummaryArguments
        do { options = try DevLiveSummaryArguments.parse(args) } catch {
            return DevCommands.usageError(usage)
        }
        do {
            try await execute(options)
            return 0
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }

    private static func execute(_ o: DevLiveSummaryArguments) async throws {
        let decoder = AutoNoteJSON.decoder()
        let transcript = try decoder.decode(Transcript.self, from: Data(contentsOf: o.live))
        let previous = try o.state.map { try decoder.decode(LiveSummaryState.self, from: Data(contentsOf: $0)) } ?? .empty
        var questions = try o.questions.map { try decoder.decode(LiveQuestionList.self, from: Data(contentsOf: $0)) }

        var state = previous
        var sent: [String] = []
        var asked: [String] = []
        if var request = LiveSummaryInputBuilder.request(previous: previous, confirmed: transcript.utterances) {
            request.questions = questions?.pendingForModel ?? []
            sent = request.questions.map(\.id)
            let summarizer: any LiveSummarizer
            if o.useClaude {
                let paths = AppPaths.resolve()
                let settings = try await SettingsStore(paths: paths).load()
                summarizer = try await LiveSummarizerFactory.make(settings: settings, paths: paths)
                try await summarizer.checkReady()
            } else {
                summarizer = FakeLiveSummarizer()
            }
            let result = try await LiveSummaryStep.run(request, summarizer: summarizer, now: Date())
            state = result.state
            asked = result.askedQuestionIDs
            questions?.markAskedByModel(asked)
        }
        let line = try (questions == nil ? DevLiveSummaryLine(state: state)
                        : DevLiveSummaryLine(state: state, sentQuestionIDs: sent, askedQuestionIDs: asked, questions: questions)).encoded()
        FileHandle.standardOutput.write(line + Data("\n".utf8))
    }
}
