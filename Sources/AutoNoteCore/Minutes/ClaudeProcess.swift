import Foundation
import os

/// Checks and helpers shared by every summarizer that runs the `claude` executable.
enum ClaudeProcess {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "ClaudeProcess")

    /// The configured path, else what `locate` finds; `.claudeNotFound(path: "")` when neither gives one.
    static func resolvePath(configured: String?, locate: @Sendable () async -> String?) async throws -> String {
        if let configured { return configured }
        guard let located = await locate() else { throw SummarizerError.claudeNotFound(path: "") }
        return located
    }

    /// Throws `.claudeNotFound(path:)` when `claudePath` is missing, a directory or not executable.
    static func checkExecutable(_ claudePath: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudePath, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: claudePath) else {
            logger.error("claude not found")
            throw SummarizerError.claudeNotFound(path: claudePath)
        }
    }

    /// Runs `claude auth status --json` with the configured environment overrides but never the extra arguments
    /// (`auth` may reject them, which would read as not logged in); throws `.notLoggedIn` unless it reports
    /// `"loggedIn": true`.
    static func checkLoggedIn(claudePath: String, runner: any ProcessRunning, workingDirectory: URL,
                              environmentOverrides: [String: String] = [:]) async throws {
        try requireLoggedIn(try await authStatus(claudePath: claudePath, runner: runner, workingDirectory: workingDirectory,
                                                 environmentOverrides: environmentOverrides))
    }

    /// The finished `claude auth status --json` run (the first half of `checkLoggedIn`), for a caller that wants to
    /// say why the check failed.
    static func authStatus(claudePath: String, runner: any ProcessRunning, workingDirectory: URL,
                           environmentOverrides: [String: String] = [:]) async throws -> ProcessResult {
        try await runner.run(executable: URL(fileURLWithPath: claudePath), arguments: ["auth", "status", "--json"],
                             stdin: Data(), workingDirectory: workingDirectory,
                             environment: environment(claudePath: claudePath, overrides: environmentOverrides),
                             timeout: ClaudeCodeSummarizer.authTimeout)
    }

    /// Throws `.notLoggedIn` unless `status` (an `authStatus` run) reports `"loggedIn": true`.
    static func requireLoggedIn(_ status: ProcessResult) throws {
        guard ClaudeResultClassifier.isLoggedIn(status) else {
            logger.error("claude auth status: not logged in (exit \(status.exitCode, privacy: .public))")
            throw SummarizerError.notLoggedIn
        }
    }

    /// The child environment for `claude`: this process's environment with the PATH it needs, then `overrides`.
    static func environment(claudePath: String, overrides: [String: String]) -> [String: String] {
        ClaudeLaunch.environment(claudePath: claudePath, base: ProcessInfo.processInfo.environment, overrides: overrides)
    }
}
