import Foundation
import os

/// Produces one live summary update during recording. Both methods throw `SummarizerError`.
public protocol LiveSummarizer: Sendable {
    /// Checks that a summary can run at all (path and login); called once per recording.
    func checkReady() async throws
    func summarize(_ r: LiveSummaryRequest) async throws -> LiveSummaryOutput
}

/// `LiveSummarizer` backed by `claude -p` with `LiveSummarySchema`, sharing the minutes summarizer's flags
/// and result classifier. Runs in its own working directory, which it never empties.
public struct ClaudeLiveSummarizer: LiveSummarizer {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "ClaudeLiveSummarizer")
    public static let defaultTimeout: Duration = .seconds(60)
    /// The longest detail (claude's own error text) in a failure log line.
    public static let failureDetailLimit = 200
    /// Writes a failure line to the unified log (subsystem `com.yutaokoshi.autonote`, category `ClaudeLiveSummarizer`).
    /// Public in the log: `failureLogLine` holds claude's error text, never the prompt or the model's output.
    public static let systemLog: @Sendable (String) -> Void = { line in
        logger.error("\(line, privacy: .public)")
    }

    public let claudePath: String
    public let model: String
    public let workingDirectory: URL
    let runner: any ProcessRunning
    let timeout: Duration
    /// `Settings.claudeArgs`, after `arguments(model:)` on every `-p` launch (not the login check; see `ClaudeLaunch`).
    public let extraArguments: [String]
    /// `Settings.claudeEnv`, over the child environment on every launch (the login check included).
    public let environmentOverrides: [String: String]
    /// Gets one `failureLogLine` per failed call.
    let log: @Sendable (String) -> Void

    public init(claudePath: String, model: String, workingDirectory: URL,
                runner: any ProcessRunning = FoundationProcessRunner(), timeout: Duration = defaultTimeout,
                extraArguments: [String] = [], environmentOverrides: [String: String] = [:],
                log: @escaping @Sendable (String) -> Void = ClaudeLiveSummarizer.systemLog) {
        self.claudePath = claudePath; self.model = model; self.workingDirectory = workingDirectory
        self.runner = runner; self.timeout = timeout
        self.extraArguments = extraArguments; self.environmentOverrides = environmentOverrides
        self.log = log
    }

    /// The minutes command line with the live schema and `--model <model>`.
    public static func arguments(model: String) -> [String] {
        ClaudeCodeSummarizer.arguments(schema: LiveSummarySchema.json, model: model)
    }

    public func checkReady() async throws {
        try ClaudeProcess.checkExecutable(claudePath)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try await ClaudeProcess.checkLoggedIn(claudePath: claudePath, runner: runner, workingDirectory: workingDirectory,
                                              environmentOverrides: environmentOverrides)
    }

    /// Does not check the login (`checkReady` does that once per recording).
    public func summarize(_ r: LiveSummaryRequest) async throws -> LiveSummaryOutput {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let result = try await runner.run(executable: URL(fileURLWithPath: claudePath),
                                          arguments: ClaudeLaunch.arguments(base: Self.arguments(model: model), extra: extraArguments),
                                          stdin: Data(LiveSummaryInputBuilder.prompt(r).utf8), workingDirectory: workingDirectory,
                                          environment: ClaudeProcess.environment(claudePath: claudePath, overrides: environmentOverrides),
                                          timeout: timeout)
        switch ClaudeResultClassifier.classify(result, as: LiveSummaryOutput.self) {
        case .success(let output):
            Self.logger.info("live claude -p succeeded (exit \(result.exitCode, privacy: .public))")
            return output
        case .failure(let error):
            log(Self.failureLogLine(error, exitCode: result.exitCode, secrets: Array(environmentOverrides.values)))
            throw error
        }
    }

    /// The log line of a failed call: the failure class, the exit code and the message `ClaudeResultClassifier` kept
    /// (an error envelope's `result` and stderr, or which part of the output did not decode). The minutes side
    /// stores the same message in `Job.summaryFailure` (`SummarizeStage.classify`); a live call has no job, so the log
    /// is the only place it can go. The classifier never copies the prompt or a successful envelope's `result` (the
    /// model's prose about the meeting) into a message. Here the message becomes one line, loses every value of
    /// `secrets` (the `claude_env` values) and anything shaped like an API key, and is cut to `failureDetailLimit`.
    static func failureLogLine(_ error: SummarizerError, exitCode: Int32, secrets: [String] = []) -> String {
        let head = "live claude -p failed: \(ClaudeCodeSummarizer.className(error)) (exit \(exitCode))"
        let message: String
        switch error {
        case .rateLimited(let m), .contextExceeded(let m), .invalidOutput(let m), .failed(_, let m): message = m
        case .claudeNotFound, .notLoggedIn, .timedOut: message = ""     // a path is not a message
        }
        var detail = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for secret in secrets where secret.count >= minimumSecretLength {
            detail = detail.replacingOccurrences(of: secret, with: "***")
        }
        detail = detail.replacing(/sk-[A-Za-z0-9_\-]{8,}/, with: "***")
        guard !detail.isEmpty else { return head }
        return head + ": " + (detail.count > failureDetailLimit ? String(detail.prefix(failureDetailLimit)) + "…" : detail)
    }

    /// Shorter `claude_env` values (`1`, `true`, a region name's fragment) are not secrets, and masking them would
    /// eat ordinary words of the message.
    static let minimumSecretLength = 8
}

/// Builds the live summarizer from the current settings (the same path resolution as `SummarizerFactory`).
public enum LiveSummarizerFactory {
    public static func make(settings: Settings, paths: AppPaths,
                            locate: @Sendable () async -> String? = { await ClaudeLocator.locate() }) async throws -> any LiveSummarizer {
        let claudePath = try await ClaudeProcess.resolvePath(configured: settings.claudePath, locate: locate)
        return ClaudeLiveSummarizer(claudePath: claudePath, model: settings.liveSummaryModel,
                                    workingDirectory: paths.liveSummaryWorkingDirectory,
                                    extraArguments: settings.claudeArgs, environmentOverrides: settings.claudeEnv)
    }
}

/// The new state and the questions the call found answered.
public struct LiveSummaryStepResult: Equatable, Sendable {
    public var state: LiveSummaryState
    /// Ids that were sent in the request, once each, in the model's order (unknown ids are dropped).
    public var askedQuestionIDs: [String]

    public init(state: LiveSummaryState, askedQuestionIDs: [String]) {
        self.state = state; self.askedQuestionIDs = askedQuestionIDs
    }
}

/// One live summary update: summarize, then fold the output into the previous state.
public enum LiveSummaryStep {
    public static func run(_ r: LiveSummaryRequest, summarizer: any LiveSummarizer, now: Date) async throws -> LiveSummaryStepResult {
        let output = try await summarizer.summarize(r)
        let sent = Set(r.questions.map(\.id))
        var seen = Set<String>()
        let asked = output.askedQuestionIDs.filter { sent.contains($0) && seen.insert($0).inserted }
        return LiveSummaryStepResult(state: r.previous.applying(output, consumedThrough: r.consumedThrough, at: now),
                                     askedQuestionIDs: asked)
    }
}
