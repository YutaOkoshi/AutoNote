import Foundation

extension AppPaths {
    /// Working directory for `claude -p` (`<root>/claude-cwd`).
    public var claudeWorkingDirectory: URL { root.appending(path: "claude-cwd", directoryHint: .isDirectory) }

    /// Working directory for the live summary's `claude -p` (`<root>/live-summary-cwd`), separate from `claude-cwd`
    /// so a live call never runs in the directory the minutes summarizer empties before each run.
    public var liveSummaryWorkingDirectory: URL { root.appending(path: "live-summary-cwd", directoryHint: .isDirectory) }
}
