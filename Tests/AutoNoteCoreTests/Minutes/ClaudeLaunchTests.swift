import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

/// `ClaudeLaunch`: how the configured extra arguments and environment variables join every `claude` launch,
/// and that the three launch sites (minutes, live summary, login check) all pass them.
@Suite struct ClaudeLaunchTests {
    private static let liveOK = #"{"type":"result","subtype":"success","is_error":false,"structured_output":{"now":"架空の話題","decisions":[],"todos":[]}}"#
    private static let minutesOK = #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"structured_output":{"title":"架空","summary":["一","二","三"],"decisions":[],"agenda":[],"next_actions":[],"suggested_terms":[]}}"#
    private static let extra = ["--settings", "/Fictional/my settings.json", "-p"]
    private static let overrides = ["CLAUDE_CONFIG_DIR": "/Fictional/claude-work"]

    // MARK: - Pure functions

    @Test func extraArgumentsFollowTheBaseInOrderUntouched() {
        #expect(ClaudeLaunch.arguments(base: ["-p", "--model", "haiku"], extra: ["b", "a", "-p"])
                == ["-p", "--model", "haiku", "b", "a", "-p"])
        #expect(ClaudeLaunch.arguments(base: ["-p"], extra: []) == ["-p"])
    }

    @Test func overridesWinOverTheChildEnvironment() {
        let env = ClaudeLaunch.environment(claudePath: "/x/claude", base: ["HOME": "/Users/fictional", "LANG": "C"],
                                           overrides: ["LANG": "ja_JP.UTF-8", "CLAUDE_CONFIG_DIR": "/Fictional/c"])
        #expect(env["LANG"] == "ja_JP.UTF-8")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/Fictional/c")
        #expect(env["HOME"] == "/Users/fictional")
        #expect(env["PATH"] == ClaudeLocator.childEnvironment(claudePath: "/x/claude", base: [:])["PATH"])
    }

    @Test func noOverridesIsTheChildEnvironment() {
        let base = ["PATH": "/opt/foo/bin", "HOME": "/Users/fictional"]
        #expect(ClaudeLaunch.environment(claudePath: "/x/claude", base: base, overrides: [:])
                == ClaudeLocator.childEnvironment(claudePath: "/x/claude", base: base))
    }

    /// The user's PATH is taken as written, without the folders AutoNote would prepend.
    @Test func pathOverrideIsKeptAsIs() {
        let env = ClaudeLaunch.environment(claudePath: "/x/claude", base: ["PATH": "/usr/bin"], overrides: ["PATH": "/only/mine"])
        #expect(env["PATH"] == "/only/mine")
    }

    // MARK: - Launch sites

    /// `auth` may reject arguments meant for `-p`, so the login check gets the environment only.
    @Test func loginCheckPassesTheEnvironmentButNoExtras() async throws {
        let runner = RecordingProcessRunner()
        try await ClaudeProcess.checkLoggedIn(claudePath: "/x/claude", runner: runner, workingDirectory: URL(filePath: "/tmp"),
                                              environmentOverrides: Self.overrides)
        let call = try #require(runner.recorded.first)
        #expect(call.arguments == ["auth", "status", "--json"])
        #expect(call.environment["CLAUDE_CONFIG_DIR"] == "/Fictional/claude-work")
        #expect(call.environment["PATH"]?.hasPrefix("/x:") == true)
    }

    @Test func minutesSummarizerPassesTheExtrasToTheSummaryCall() async throws {
        let dir = try TemporaryDirectory.make()
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), responses: [])
        let runner = RecordingProcessRunner(responses: [Self.minutesOK])
        let s = ClaudeCodeSummarizer(claudePath: claude.path(percentEncoded: false), model: "sonnet",
                                     workingDirectory: dir.appending(path: "work"), runner: runner,
                                     extraArguments: Self.extra, environmentOverrides: Self.overrides)
        _ = try await s.summarize(SummaryInput(instructions: "指示", terms: [], bookmarks: [],
                                               transcript: Transcript(utterances: [], engine: "whisper", language: .ja),
                                               language: .ja))
        let calls = runner.recorded
        #expect(calls.count == 2)
        #expect(calls[0].arguments == ["auth", "status", "--json"])
        #expect(calls[1].arguments == ClaudeCodeSummarizer.arguments(model: "sonnet") + Self.extra)
        for call in calls { #expect(call.environment["CLAUDE_CONFIG_DIR"] == "/Fictional/claude-work") }
    }

    @Test func liveSummarizerPassesTheExtrasToTheSummaryCall() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), responses: [])
        let runner = RecordingProcessRunner(responses: [Self.liveOK])
        let live = ClaudeLiveSummarizer(claudePath: claude.path(percentEncoded: false), model: "haiku",
                                        workingDirectory: paths.liveSummaryWorkingDirectory, runner: runner,
                                        extraArguments: Self.extra, environmentOverrides: Self.overrides)
        try await live.checkReady()
        _ = try await live.summarize(LiveSummaryRequest(previous: .empty, utterances: [], consumedThrough: 0))
        let calls = runner.recorded
        #expect(calls.count == 2)
        #expect(calls[0].arguments == ["auth", "status", "--json"])
        #expect(calls[1].arguments == ClaudeLiveSummarizer.arguments(model: "haiku") + Self.extra)
        for call in calls { #expect(call.environment["CLAUDE_CONFIG_DIR"] == "/Fictional/claude-work") }
    }

    /// The real child process sees the variable (the fake `claude` writes its environment out).
    @Test func claudeConfigDirReachesTheChildProcess() async throws {
        let dir = try TemporaryDirectory.make()
        let script = dir.appending(path: "claude")
        let out = dir.appending(path: "env-out").path(percentEncoded: false)
        try Data("#!/bin/sh\nprintf '%s' \"$CLAUDE_CONFIG_DIR\" > '\(out)'\necho '{\"loggedIn\":true}'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        try await ClaudeProcess.checkLoggedIn(claudePath: script.path(percentEncoded: false), runner: FoundationProcessRunner(),
                                              workingDirectory: dir, environmentOverrides: ["CLAUDE_CONFIG_DIR": "/Fictional/claude-work"])
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "/Fictional/claude-work")
    }

    // MARK: - Factories read the settings

    @Test func factoriesPassTheSettings() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        var settings = Settings()
        settings.claudePath = "/opt/fake/claude"
        settings.claudeArgs = Self.extra
        settings.claudeEnv = Self.overrides
        let minutes = try #require(try await SummarizerFactory.make(settings: settings, paths: paths) as? ClaudeCodeSummarizer)
        #expect(minutes.extraArguments == Self.extra)
        #expect(minutes.environmentOverrides == Self.overrides)
        let live = try #require(try await LiveSummarizerFactory.make(settings: settings, paths: paths, locate: { nil })
                                as? ClaudeLiveSummarizer)
        #expect(live.extraArguments == Self.extra)
        #expect(live.environmentOverrides == Self.overrides)
    }

    @Test func defaultsAddNothing() {
        let s = ClaudeCodeSummarizer(claudePath: "/x/claude", model: nil, workingDirectory: URL(filePath: "/tmp"))
        #expect(s.extraArguments.isEmpty && s.environmentOverrides.isEmpty)
        let l = ClaudeLiveSummarizer(claudePath: "/x/claude", model: "haiku", workingDirectory: URL(filePath: "/tmp"))
        #expect(l.extraArguments.isEmpty && l.environmentOverrides.isEmpty)
    }
}
