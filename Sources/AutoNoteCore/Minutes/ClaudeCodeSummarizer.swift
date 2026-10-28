import Foundation
import os

/// `Summarizer` backed by `claude -p` (requirements §8.1). Runs one child process at a time.
public struct ClaudeCodeSummarizer: Summarizer {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "ClaudeCodeSummarizer")
    static let authTimeout: Duration = .seconds(30)

    public let claudePath: String
    public let model: String?
    public let workingDirectory: URL
    public let runner: any ProcessRunning
    public let timeout: Duration
    public let builder: PromptBuilder

    public init(claudePath: String, model: String?, workingDirectory: URL, runner: any ProcessRunning = FoundationProcessRunner(),
                timeout: Duration = .seconds(600), builder: PromptBuilder = PromptBuilder()) {
        self.claudePath = claudePath; self.model = model; self.workingDirectory = workingDirectory
        self.runner = runner; self.timeout = timeout; self.builder = builder
    }

    /// The spec command line verbatim; only `--model <name>` may be appended.
    public static func arguments(model: String?) -> [String] {
        arguments(schema: MinutesSchema.json, model: model)
    }

    /// The spec command line with `schema` as `--json-schema`; shared by the minutes and live summarizers.
    public static func arguments(schema: String, model: String?) -> [String] {
        var args = ["-p", "--output-format", "json", "--json-schema", schema, "--tools", "",
                    "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                    "--no-session-persistence", "--max-turns", "1", "--setting-sources", "project"]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    public func summarize(_ input: SummaryInput) async throws -> MinutesOutput {
        try ClaudeProcess.checkExecutable(claudePath)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try await ClaudeProcess.checkLoggedIn(claudePath: claudePath, runner: runner, workingDirectory: workingDirectory)
        try emptyWorkingDirectory()

        switch builder.plan(input) {
        case .single(let prompt):
            do {
                return try await run(prompt)
            } catch SummarizerError.contextExceeded(let message) {
                guard case .split(let parts) = builder.plan(input, minimumParts: 2) else {
                    throw SummarizerError.contextExceeded(message: message)
                }
                Self.logger.info("context exceeded; retrying split into \(parts.count, privacy: .public) parts")
                return try await runSplit(parts, instructions: input.instructions)
            }
        case .split(let parts):
            return try await runSplit(parts, instructions: input.instructions)
        }
    }

    /// Removes everything inside the working directory. Entries are removed as themselves (symlinks are not followed).
    private func emptyWorkingDirectory() throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: workingDirectory.path(percentEncoded: false)) {
            try fm.removeItem(at: workingDirectory.appending(path: name))
        }
    }

    private func runSplit(_ parts: [String], instructions: String) async throws -> MinutesOutput {
        var partials: [MinutesOutput] = []
        for part in parts { partials.append(try await run(part)) }
        return try await run(builder.mergePrompt(instructions: instructions, partials: partials))
    }

    private func run(_ prompt: String) async throws -> MinutesOutput {
        let result = try await runner.run(executable: URL(fileURLWithPath: claudePath), arguments: Self.arguments(model: model),
                                          stdin: Data(prompt.utf8), workingDirectory: workingDirectory,
                                          environment: ClaudeProcess.environment(claudePath: claudePath), timeout: timeout)
        switch ClaudeResultClassifier.classify(result) {
        case .success(let output):
            Self.logger.info("claude -p succeeded (exit \(result.exitCode, privacy: .public))")
            return output
        case .failure(let error):
            Self.logger.error("claude -p failed: \(Self.className(error), privacy: .public) (exit \(result.exitCode, privacy: .public))")
            throw error
        }
    }

    static func className(_ error: SummarizerError) -> String {
        switch error {
        case .claudeNotFound: "claudeNotFound"
        case .notLoggedIn: "notLoggedIn"
        case .rateLimited: "rateLimited"
        case .contextExceeded: "contextExceeded"
        case .timedOut: "timedOut"
        case .invalidOutput: "invalidOutput"
        case .failed: "failed"
        }
    }
}
