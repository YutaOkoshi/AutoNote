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

    public let claudePath: String
    public let model: String
    public let workingDirectory: URL
    let runner: any ProcessRunning
    let timeout: Duration

    public init(claudePath: String, model: String, workingDirectory: URL,
                runner: any ProcessRunning = FoundationProcessRunner(), timeout: Duration = defaultTimeout) {
        self.claudePath = claudePath; self.model = model; self.workingDirectory = workingDirectory
        self.runner = runner; self.timeout = timeout
    }

    /// The minutes command line with the live schema and `--model <model>`.
    public static func arguments(model: String) -> [String] {
        ClaudeCodeSummarizer.arguments(schema: LiveSummarySchema.json, model: model)
    }

    public func checkReady() async throws {
        try ClaudeProcess.checkExecutable(claudePath)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try await ClaudeProcess.checkLoggedIn(claudePath: claudePath, runner: runner, workingDirectory: workingDirectory)
    }

    /// Does not check the login (`checkReady` does that once per recording).
    public func summarize(_ r: LiveSummaryRequest) async throws -> LiveSummaryOutput {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let result = try await runner.run(executable: URL(fileURLWithPath: claudePath), arguments: Self.arguments(model: model),
                                          stdin: Data(LiveSummaryInputBuilder.prompt(r).utf8), workingDirectory: workingDirectory,
                                          environment: ClaudeProcess.environment(claudePath: claudePath), timeout: timeout)
        switch ClaudeResultClassifier.classify(result, as: LiveSummaryOutput.self) {
        case .success(let output):
            Self.logger.info("live claude -p succeeded (exit \(result.exitCode, privacy: .public))")
            return output
        case .failure(let error):
            Self.logger.error("live claude -p failed: \(ClaudeCodeSummarizer.className(error), privacy: .public) (exit \(result.exitCode, privacy: .public))")
            throw error
        }
    }
}

/// Builds the live summarizer from the current settings (the same path resolution as `SummarizerFactory`).
public enum LiveSummarizerFactory {
    public static func make(settings: Settings, paths: AppPaths,
                            locate: @Sendable () async -> String? = { await ClaudeLocator.locate() }) async throws -> any LiveSummarizer {
        let claudePath = try await ClaudeProcess.resolvePath(configured: settings.claudePath, locate: locate)
        return ClaudeLiveSummarizer(claudePath: claudePath, model: settings.liveSummaryModel,
                                    workingDirectory: paths.liveSummaryWorkingDirectory)
    }
}

/// One live summary update: summarize, then fold the output into the previous state.
public enum LiveSummaryStep {
    public static func run(_ r: LiveSummaryRequest, summarizer: any LiveSummarizer, now: Date) async throws -> LiveSummaryState {
        let output = try await summarizer.summarize(r)
        return r.previous.applying(output, consumedThrough: r.consumedThrough, at: now)
    }
}
