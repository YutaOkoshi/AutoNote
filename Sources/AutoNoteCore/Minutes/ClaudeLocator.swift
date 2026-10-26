import Foundation

/// Finds the `claude` executable. GUI apps do not inherit the login shell's PATH, so the login shell is asked first.
public enum ClaudeLocator {
    /// Searched in this order after the login shell; `~` is the user's home folder.
    public static let fallbackCandidates: [String] = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let loginShellTimeout: Duration = .seconds(5)

    /// The first executable among the login shell's answer and `fallbackCandidates`, or nil.
    public static func locate(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        loginShellLookup: @Sendable () async -> String? = ClaudeLocator.loginShellLookup,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> String? {
        if let fromShell = await loginShellLookup(), isExecutable(fromShell) { return fromShell }
        let homePath = home.path(percentEncoded: false).replacing(/\/+$/, with: "")
        for candidate in fallbackCandidates {
            let path = candidate.hasPrefix("~/") ? homePath + candidate.dropFirst() : candidate
            if isExecutable(path) { return path }
        }
        return nil
    }

    /// First line of `/bin/zsh -lc 'command -v claude'`, if it is an absolute path. Gives up after 5 s.
    public static func loginShellLookup() async -> String? {
        guard let result = try? await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v claude"], stdin: Data(),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment, timeout: loginShellTimeout),
              result.exitCode == 0, !result.timedOut else { return nil }
        let firstLine = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.hasPrefix("/") ? firstLine : nil
    }

    /// Fills `Settings.claudePath` only when it is unset; returns the value stored afterwards.
    @discardableResult
    public static func fillDefaultPath(
        _ store: SettingsStore,
        locate: @Sendable () async -> String? = { await ClaudeLocator.locate() }
    ) async throws -> String? {
        if let existing = try await store.load().claudePath { return existing }
        guard let found = await locate() else { return nil }
        return try await store.update { settings in
            if settings.claudePath == nil { settings.claudePath = found }
        }.claudePath
    }

    /// The parent's environment with the folder of `claudePath` and the system folders prepended to `PATH`.
    public static func childEnvironment(claudePath: String, base: [String: String]) -> [String: String] {
        let folder = URL(fileURLWithPath: claudePath).deletingLastPathComponent().path(percentEncoded: false)
            .replacing(/(.)\/+$/, with: { $0.output.1 })
        var env = base
        let prefix = folder + ":" + systemPath
        if let existing = base["PATH"], !existing.isEmpty {
            env["PATH"] = prefix + ":" + existing
        } else {
            env["PATH"] = prefix
        }
        return env
    }
}
