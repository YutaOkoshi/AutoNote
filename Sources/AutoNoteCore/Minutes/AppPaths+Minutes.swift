import Foundation

extension AppPaths {
    /// Working directory for `claude -p` (`<root>/claude-cwd`).
    public var claudeWorkingDirectory: URL { root.appending(path: "claude-cwd", directoryHint: .isDirectory) }
}
