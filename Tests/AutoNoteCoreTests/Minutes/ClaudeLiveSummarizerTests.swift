import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct ClaudeLiveSummarizerTests {
    private static let ok = #"{"type":"result","subtype":"success","is_error":false,"structured_output":{"now":"架空の話題","decisions":["架空の決定"],"todos":[{"text":"架空の宿題","owner":null,"side":"other"}],"asked_question_ids":["q1"]}}"#

    private func request() -> LiveSummaryRequest {
        let previous = LiveSummaryState(now: "前の話題", decisions: ["前の決定"], todos: [], consumedThrough: 40, updatedAt: nil)
        let u = [Utterance(start: TimelineTime(seconds: 50), end: TimelineTime(seconds: 85), speaker: .me, text: "架空の発話", isFinal: true)]
        return LiveSummaryRequest(previous: previous, utterances: u, consumedThrough: 85)
    }

    private func summarizer(_ claude: URL, paths: AppPaths, model: String = "haiku") -> ClaudeLiveSummarizer {
        ClaudeLiveSummarizer(claudePath: claude.path(percentEncoded: false), model: model,
                             workingDirectory: paths.liveSummaryWorkingDirectory)
    }

    private func failure(_ body: () async throws -> Void) async -> SummarizerError? {
        do { try await body(); return nil } catch let e as SummarizerError { return e } catch { return nil }
    }

    private func result(_ s: String) -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(s.utf8), stderr: Data(), timedOut: false)
    }

    @Test func liveArgumentsShareTheMinutesFlags() {
        let live = ClaudeLiveSummarizer.arguments(model: "haiku")
        #expect(live == ClaudeCodeSummarizer.arguments(schema: LiveSummarySchema.json, model: "haiku"))
        #expect(live.suffix(2) == ["--model", "haiku"])
        for flag in ["--strict-mcp-config", "--no-session-persistence", "--setting-sources"] { #expect(live.contains(flag)) }
        #expect(ClaudeCodeSummarizer.arguments(model: nil) == ClaudeCodeSummarizer.arguments(schema: MinutesSchema.json, model: nil))
    }

    @Test func liveSchemaRequiresTheFourKeys() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(LiveSummarySchema.json.utf8)) as? [String: Any])
        #expect(schema["required"] as? [String] == ["now", "decisions", "todos", "asked_question_ids"])
        let properties = try #require(schema["properties"] as? [String: Any])
        let now = try #require(properties["now"] as? [String: Any])
        #expect(now["maxLength"] as? Int == 60)
    }

    @Test func summarizeSendsThePromptInItsOwnDirectory() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), auth: #"{"loggedIn":false}"#, responses: [Self.ok])
        let r = request()
        let out = try await summarizer(claude, paths: paths).summarize(r)
        #expect(out == LiveSummaryOutput(now: "架空の話題", decisions: ["架空の決定"], todos: [.init(text: "架空の宿題", owner: nil, side: .other)],
                                         askedQuestionIDs: ["q1"]))
        let fake = dir.appending(path: "fake")
        #expect(FakeClaude.count(in: fake) == 1)
        #expect(try FakeClaude.stdin(in: fake, call: 1) == LiveSummaryInputBuilder.prompt(r))
        #expect(try FakeClaude.arguments(in: fake, call: 1) == ClaudeLiveSummarizer.arguments(model: "haiku"))
        // `resolvingSymlinksInPath` drops `/private`, while `pwd -P` keeps it; `realpath` matches `pwd -P`.
        let real = try #require(realpath(paths.liveSummaryWorkingDirectory.path(percentEncoded: false), nil))
        defer { free(real) }
        let cwd = try FakeClaude.cwd(in: fake, call: 1)
        #expect(cwd == String(cString: real))
        #expect(!cwd.hasSuffix("/claude-cwd"))
    }

    @Test func checkReadyChecksPathAndLogin() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let missing = dir.appending(path: "missing/claude")
        let e1 = await failure { try await summarizer(missing, paths: paths).checkReady() }
        #expect(e1 == .claudeNotFound(path: missing.path(percentEncoded: false)))

        let out = dir.appending(path: "out")
        let loggedOut = try FakeClaude.make(in: out, auth: #"{"loggedIn":false}"#, responses: [Self.ok])
        let e2 = await failure { try await summarizer(loggedOut, paths: paths).checkReady() }
        #expect(e2 == .notLoggedIn)

        let inside = dir.appending(path: "in")
        let loggedIn = try FakeClaude.make(in: inside, responses: [Self.ok])
        try await summarizer(loggedIn, paths: paths).checkReady()
        #expect(FakeClaude.count(in: inside) == 0)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.liveSummaryWorkingDirectory.path(percentEncoded: false),
                                               isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func rateLimitIsClassified() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"),
                                         responses: [#"{"type":"result","is_error":true,"result":"You've hit your limit"}"#])
        let e = await failure { _ = try await summarizer(claude, paths: paths).summarize(request()) }
        guard case .rateLimited = e else {
            Issue.record("expected rateLimited, got \(String(describing: e))")
            return
        }
    }

    /// The envelope a real `claude -p` (2.1.332) printed for a model it does not know (exit 1), with a made-up name.
    /// The real run also wrote one line to stderr (`[claude-code:unrecognized_model] {…}`), which follows in the log.
    private static let unknownModel = #"{"type":"result","subtype":"success","is_error":true,"num_turns":1,"result":"There's an issue with the selected model (no-such-model). It may not exist or you may not have access to it. Run --model to pick a different model."}"#

    @Test func aFailedCallLogsWhatClaudeSaid() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), responses: [Self.unknownModel], exitCode: 1)
        let logs = LockedBox<[String]>([])
        let live = ClaudeLiveSummarizer(claudePath: claude.path(percentEncoded: false), model: "no-such-model",
                                        workingDirectory: paths.liveSummaryWorkingDirectory,
                                        log: { line in logs.withLock { $0.append(line) } })
        let e = await failure { _ = try await live.summarize(request()) }
        guard case .failed(let exitCode, let message) = e else {
            Issue.record("expected failed, got \(String(describing: e))")
            return
        }
        #expect(exitCode == 1)
        let lines = logs.withLock { $0 }
        #expect(lines == ["live claude -p failed: failed (exit 1): \(message)"])
        #expect(lines.first?.contains("issue with the selected model (no-such-model)") == true)
        // The prompt (the utterances) never reaches the log.
        #expect(lines.allSatisfy { !$0.contains("架空の発話") })
    }

    /// `notLoggedIn` stands for four different errors and carries no message: the line says which one it was.
    @Test func aCallClassifiedAsNotLoggedInLogsWhatClaudeSaid() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let envelope = #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Fix external API key"}"#
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), responses: [envelope], exitCode: 1)
        let logs = LockedBox<[String]>([])
        let live = ClaudeLiveSummarizer(claudePath: claude.path(percentEncoded: false), model: "haiku",
                                        workingDirectory: paths.liveSummaryWorkingDirectory,
                                        log: { line in logs.withLock { $0.append(line) } })
        let e = await failure { _ = try await live.summarize(request()) }
        #expect(e == .notLoggedIn)
        #expect(logs.withLock { $0 } == ["live claude -p failed: notLoggedIn (exit 1): Invalid API key · Fix external API key"])
    }

    /// Nothing on stdout that is an envelope and nothing on stderr: the line gives the shape of the output, sizes only.
    @Test func aFailureWithoutAnyTextLogsTheShapeOfTheOutput() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), responses: ["made-up output"], exitCode: 1)
        let logs = LockedBox<[String]>([])
        let live = ClaudeLiveSummarizer(claudePath: claude.path(percentEncoded: false), model: "haiku",
                                        workingDirectory: paths.liveSummaryWorkingDirectory,
                                        log: { line in logs.withLock { $0.append(line) } })
        let e = await failure { _ = try await live.summarize(request()) }
        #expect(e == .failed(exitCode: 1, message: ""))
        #expect(logs.withLock { $0 } == [
            "live claude -p failed: failed (exit 1): no error text (stdout 14 bytes, not a JSON object; stderr 0 bytes)",
        ])
        #expect(logs.withLock { $0 }.allSatisfy { !$0.contains("made-up output") })
    }

    private struct ThrowingRunner: ProcessRunning {
        var error: any Error & Sendable
        func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
                 environment: [String: String], timeout: Duration) async throws -> ProcessResult { throw error }
    }

    /// A call that never ran (claude could not be started) says so, by error type and code; a cancelled one says nothing.
    @Test func aCallThatNeverRanIsLoggedUnlessCancelled() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let logs = LockedBox<[String]>([])
        func live(_ error: any Error & Sendable) -> ClaudeLiveSummarizer {
            ClaudeLiveSummarizer(claudePath: "/Fictional/claude", model: "haiku", workingDirectory: paths.liveSummaryWorkingDirectory,
                                 runner: ThrowingRunner(error: error), log: { line in logs.withLock { $0.append(line) } })
        }
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSFilePathErrorKey: "/Users/someone/claude"])
        await #expect(throws: (any Error).self) { _ = try await live(posix).summarize(request()) }
        #expect(logs.withLock { $0 } == ["live claude -p did not run: NSError (NSPOSIXErrorDomain 13)"])
        await #expect(throws: CancellationError.self) { _ = try await live(CancellationError()).summarize(request()) }
        #expect(logs.withLock { $0 }.count == 1)
    }

    @Test func aSuccessfulCallLogsNoFailure() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), responses: [Self.ok])
        let logs = LockedBox<[String]>([])
        let live = ClaudeLiveSummarizer(claudePath: claude.path(percentEncoded: false), model: "haiku",
                                        workingDirectory: paths.liveSummaryWorkingDirectory,
                                        log: { line in logs.withLock { $0.append(line) } })
        _ = try await live.summarize(request())
        #expect(logs.withLock { $0 }.isEmpty)
    }

    @Test func failureLogLineIsOneShortLineWithoutSecrets() {
        // Nothing to add: the line is as it was.
        #expect(ClaudeLiveSummarizer.failureLogLine(.timedOut, exitCode: -1) == "live claude -p failed: timedOut (exit -1)")
        #expect(ClaudeLiveSummarizer.failureLogLine(.timedOut, exitCode: -1, otherwise: "no error text") == "live claude -p failed: timedOut (exit -1)")
        // A class without a message, or an empty one, takes what the caller found instead.
        #expect(ClaudeLiveSummarizer.failureLogLine(.notLoggedIn, exitCode: 1, otherwise: "authentication_error")
                == "live claude -p failed: notLoggedIn (exit 1): authentication_error")
        #expect(ClaudeLiveSummarizer.failureLogLine(.failed(exitCode: 1, message: " \n"), exitCode: 1, otherwise: "no error text")
                == "live claude -p failed: failed (exit 1): no error text")
        #expect(ClaudeLiveSummarizer.failureLogLine(.failed(exitCode: 1, message: ""), exitCode: 1)
                == "live claude -p failed: failed (exit 1)")
        // A path is not a message (`claudeNotFound` carries one).
        #expect(ClaudeLiveSummarizer.failureLogLine(.claudeNotFound(path: "/Users/someone/bin/claude"), exitCode: 1)
                == "live claude -p failed: claudeNotFound (exit 1)")
        // Line breaks and runs of blanks become one space.
        #expect(ClaudeLiveSummarizer.failureLogLine(.failed(exitCode: 2, message: "first\n\n  second\tthird\r\n"), exitCode: 2)
                == "live claude -p failed: failed (exit 2): first second third")
        // The other classes keep their message too.
        #expect(ClaudeLiveSummarizer.failureLogLine(.invalidOutput(message: "subtype=error_max_turns: no structured_output"), exitCode: 1)
                == "live claude -p failed: invalidOutput (exit 1): subtype=error_max_turns: no structured_output")
        // Cut to the limit, with a mark that it was cut.
        let long = String(repeating: "x", count: 600)
        let cut = ClaudeLiveSummarizer.failureLogLine(.failed(exitCode: 1, message: long), exitCode: 1)
        #expect(cut == "live claude -p failed: failed (exit 1): " + String(repeating: "x", count: ClaudeLiveSummarizer.failureDetailLimit) + "…")
        // A `claude_env` value and an API-key-shaped token are masked wherever they appear.
        let secret = ClaudeLiveSummarizer.failureLogLine(
            .failed(exitCode: 1, message: "bad token made-up-value-123 or sk-ant-abc_DEF-0123456789 in request"),
            exitCode: 1, secrets: ["made-up-value-123", "", "in"])
        #expect(secret == "live claude -p failed: failed (exit 1): bad token *** or *** in request")
        // A value with blanks in it is masked as written (before the message becomes one line).
        let spaced = ClaudeLiveSummarizer.failureLogLine(
            .failed(exitCode: 1, message: "header was made-up  two\twords here"), exitCode: 1, secrets: ["made-up  two\twords"])
        #expect(spaced == "live claude -p failed: failed (exit 1): header was *** here")
        // A value that starts with another one is masked whole, whatever order the values come in.
        for secrets in [["made-up-token", "made-up-token-AAAA-BBBB"], ["made-up-token-AAAA-BBBB", "made-up-token"]] {
            #expect(ClaudeLiveSummarizer.failureLogLine(.failed(exitCode: 1, message: "token made-up-token-AAAA-BBBB rejected"),
                                                        exitCode: 1, secrets: secrets)
                    == "live claude -p failed: failed (exit 1): token *** rejected")
        }
        // `sk-` inside a word is not a key.
        #expect(ClaudeLiveSummarizer.failureLogLine(.failed(exitCode: 1, message: "task-notification failed; disk-space-low"), exitCode: 1)
                == "live claude -p failed: failed (exit 1): task-notification failed; disk-space-low")
    }

    @Test func defaultTimeoutIsSixtySeconds() {
        #expect(ClaudeLiveSummarizer.defaultTimeout == .seconds(60))
    }

    @Test func classifierDecodesAnyOutputType() {
        guard case .success(let out) = ClaudeResultClassifier.classify(result(Self.ok), as: LiveSummaryOutput.self) else {
            Issue.record("expected success")
            return
        }
        #expect(out.now == "架空の話題")
        let bad = #"{"type":"result","subtype":"success","is_error":false,"structured_output":{"now":1}}"#
        guard case .failure(.invalidOutput(let message)) = ClaudeResultClassifier.classify(result(bad), as: LiveSummaryOutput.self) else {
            Issue.record("expected invalidOutput")
            return
        }
        #expect(message.hasPrefix("subtype=success: structured_output invalid at"))
    }

    @Test func factoryUsesTheLiveSettings() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), responses: [Self.ok])
        var settings = Settings()
        settings.claudePath = claude.path(percentEncoded: false)
        settings.liveSummaryModel = "sonnet"
        let made = try await LiveSummarizerFactory.make(settings: settings, paths: paths, locate: { nil })
        let live = try #require(made as? ClaudeLiveSummarizer)
        #expect(live.model == "sonnet")
        #expect(live.claudePath == claude.path(percentEncoded: false))
        #expect(live.workingDirectory == paths.liveSummaryWorkingDirectory)

        settings.claudePath = nil
        let e = await failure { _ = try await LiveSummarizerFactory.make(settings: settings, paths: paths, locate: { nil }) }
        #expect(e == .claudeNotFound(path: ""))
    }

    @Test func stepAppliesTheOutput() async throws {
        let r = request()
        let s = try await LiveSummaryStep.run(r, summarizer: FakeLiveSummarizer(), now: Samples.start).state
        #expect(s.consumedThrough == r.consumedThrough)
        #expect(s.updatedAt == Samples.start)
        #expect(s.decisions == r.previous.decisions + ["決定（85 秒まで）"])
    }

    @Test func liveWorkingDirectoryIsSeparate() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(paths.liveSummaryWorkingDirectory == paths.root.appending(path: "live-summary-cwd", directoryHint: .isDirectory))
    }
}
