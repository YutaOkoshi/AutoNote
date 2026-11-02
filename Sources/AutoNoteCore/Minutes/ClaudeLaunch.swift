import Foundation

/// The one place a `claude` command line and child environment are put together from the settings'
/// `claude_args` / `claude_env`. Every launch (minutes, live summary, login check) goes through here; the login
/// check (`claude auth status --json`) takes only the environment, never the extra arguments.
public enum ClaudeLaunch {
    /// AutoNote's own arguments, then the user's extra ones as written (duplicates such as a second `-p` are kept).
    public static func arguments(base: [String], extra: [String]) -> [String] {
        base + extra
    }

    /// `ClaudeLocator.childEnvironment` with `overrides` on top. An overridden `PATH` is used as written:
    /// the user's choice wins over the folders AutoNote would prepend.
    public static func environment(claudePath: String, base: [String: String],
                                   overrides: [String: String]) -> [String: String] {
        ClaudeLocator.childEnvironment(claudePath: claudePath, base: base).merging(overrides) { _, override in override }
    }
}
