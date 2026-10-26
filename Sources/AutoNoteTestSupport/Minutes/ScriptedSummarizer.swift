import AutoNoteCore
import Foundation

/// Returns `results` in order, one per call; records every input. Calls past the end fail with `.failed`.
public actor ScriptedSummarizer: Summarizer {
    private var results: [Result<MinutesOutput, SummarizerError>]
    public private(set) var inputs: [SummaryInput] = []

    public init(results: [Result<MinutesOutput, SummarizerError>]) { self.results = results }

    public func summarize(_ input: SummaryInput) async throws -> MinutesOutput {
        inputs.append(input)
        guard !results.isEmpty else {
            throw SummarizerError.failed(exitCode: -1, message: "ScriptedSummarizer has no results left")
        }
        return try results.removeFirst().get()
    }
}
