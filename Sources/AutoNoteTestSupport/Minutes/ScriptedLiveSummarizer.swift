import AutoNoteCore
import Foundation

/// Returns `results` in order, one per call, and records every request. Once they run out, call n returns
/// `now: "呼び出し n"` with the previous decisions and todos. `hold()` parks the next single call until `release()`.
public actor ScriptedLiveSummarizer: LiveSummarizer {
    private let ready: SummarizerError?
    private var results: [Result<LiveSummaryOutput, SummarizerError>]
    public private(set) var requests: [LiveSummaryRequest] = []
    public private(set) var readyChecks = 0
    public private(set) var inFlight = 0
    public private(set) var maxConcurrent = 0
    private var holdNext = false
    private var held: [CheckedContinuation<Void, Never>] = []

    public init(ready: SummarizerError? = nil, results: [Result<LiveSummaryOutput, SummarizerError>] = []) {
        self.ready = ready; self.results = results
    }

    public func checkReady() async throws {
        readyChecks += 1
        if let ready { throw ready }
    }

    public func summarize(_ r: LiveSummaryRequest) async throws -> LiveSummaryOutput {
        requests.append(r)
        let n = requests.count
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        defer { inFlight -= 1 }
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held.append($0) }
        }
        guard !results.isEmpty else {
            return LiveSummaryOutput(now: "呼び出し \(n)", decisions: r.previous.decisions, todos: r.previous.todos)
        }
        return try results.removeFirst().get()
    }

    /// The next call (only that one) waits until `release()`.
    public func hold() { holdNext = true }

    /// Resumes the held calls; a pending `hold()` that no call has taken yet is cancelled.
    public func release() {
        holdNext = false
        let waiting = held
        held = []
        for c in waiting { c.resume() }
    }
}
