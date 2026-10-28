import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct ClaudeLiveSummarizerTests {
    private static let ok = #"{"type":"result","subtype":"success","is_error":false,"structured_output":{"now":"架空の話題","decisions":["架空の決定"],"todos":[{"text":"架空の宿題","owner":null}]}}"#

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

    @Test func liveSchemaRequiresTheThreeKeys() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(LiveSummarySchema.json.utf8)) as? [String: Any])
        #expect(schema["required"] as? [String] == ["now", "decisions", "todos"])
        let properties = try #require(schema["properties"] as? [String: Any])
        let now = try #require(properties["now"] as? [String: Any])
        #expect(now["maxLength"] as? Int == 60)
    }

    @Test func summarizeSendsThePromptInItsOwnDirectory() async throws {
        let dir = try TemporaryDirectory.make(), paths = AppPaths(root: dir.appending(path: "root"))
        let claude = try FakeClaude.make(in: dir.appending(path: "fake"), auth: #"{"loggedIn":false}"#, responses: [Self.ok])
        let r = request()
        let out = try await summarizer(claude, paths: paths).summarize(r)
        #expect(out == LiveSummaryOutput(now: "架空の話題", decisions: ["架空の決定"], todos: [.init(text: "架空の宿題", owner: nil)]))
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
        let s = try await LiveSummaryStep.run(r, summarizer: FakeLiveSummarizer(), now: Samples.start)
        #expect(s.consumedThrough == r.consumedThrough)
        #expect(s.updatedAt == Samples.start)
        #expect(s.decisions == r.previous.decisions + ["決定（85 秒まで）"])
    }

    @Test func liveWorkingDirectoryIsSeparate() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(paths.liveSummaryWorkingDirectory == paths.root.appending(path: "live-summary-cwd", directoryHint: .isDirectory))
    }
}
