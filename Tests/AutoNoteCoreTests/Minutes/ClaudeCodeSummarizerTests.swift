import Testing
import Foundation
@testable import AutoNoteCore

@Suite struct ClaudeCodeSummarizerTests {
    private static let specArguments: [String] = [
        "-p", "--output-format", "json", "--json-schema", MinutesSchema.json, "--tools", "",
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
        "--no-session-persistence", "--max-turns", "1", "--setting-sources", "project",
    ]

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ClaudeCodeSummarizerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func success(title: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"num_turns":2,"structured_output":{"title":"\#(title)","summary":["一","二","三"],"decisions":[{"text":"架空の決定","t":"00:01:00"}],"agenda":[{"title":"議題","body":"本文","t":"00:00:10"}],"next_actions":[{"text":"資料を作る","owner":null,"due":null,"t":"00:02:00"}],"suggested_terms":["架空語"]}}"#
    }

    private static let tooLong = #"{"type":"result","subtype":"success","is_error":true,"result":"Prompt is too long"}"#

    private func input(_ n: Int = 4, chars: Int = 20) -> SummaryInput {
        let u = (0..<n).map { i in
            Utterance(start: TimelineTime(seconds: Double(i) * 10), speaker: i % 2 == 0 ? .me : .other,
                      text: String(repeating: "あ", count: chars), isFinal: true)
        }
        return SummaryInput(instructions: "指示X", terms: ["用語A"], bookmarks: [],
                            transcript: Transcript(utterances: u, engine: "whisper", language: .ja), language: .ja)
    }

    private func summarizer(_ claude: URL, work: URL, timeout: Duration = .seconds(30)) -> ClaudeCodeSummarizer {
        ClaudeCodeSummarizer(claudePath: claude.path(percentEncoded: false), model: nil, workingDirectory: work, timeout: timeout)
    }

    private func caseName(_ e: SummarizerError) -> String { ClaudeCodeSummarizer.className(e) }

    private func failure(_ body: () async throws -> MinutesOutput) async -> SummarizerError? {
        do { _ = try await body(); return nil } catch let e as SummarizerError { return e } catch { return nil }
    }

    @Test func argumentsMatchSpecVerbatim() {
        #expect(ClaudeCodeSummarizer.arguments(model: nil) == Self.specArguments)
        #expect(ClaudeCodeSummarizer.arguments(model: "") == Self.specArguments)
        let withModel = ClaudeCodeSummarizer.arguments(model: "opus")
        #expect(withModel == Self.specArguments + ["--model", "opus"])
    }

    @Test func schemaMatchesScriptsFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = try Data(contentsOf: root.appending(path: "scripts/minutes-schema.json"))
        let a = try JSONSerialization.jsonObject(with: file) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(MinutesSchema.json.utf8)) as? NSDictionary
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func successReturnsStructuredOutput() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work dir")
        let claude = try FakeClaude.make(in: dir, responses: [success(title: "架空の定例")])
        let out = try await summarizer(claude, work: work).summarize(input())
        #expect(out.title == "架空の定例")
        #expect(out.nextActions.first?.owner == nil)
        #expect(FakeClaude.count(in: dir) == 1)
        #expect(try FakeClaude.arguments(in: dir, call: 1) == ClaudeCodeSummarizer.arguments(model: nil))
        let real = try #require(realpath(work.path(percentEncoded: false), nil))
        defer { free(real) }
        #expect(try FakeClaude.cwd(in: dir, call: 1) == String(cString: real))
        #expect(try FakeClaude.stdin(in: dir, call: 1).contains(DefaultPrompt.dataNotice))
    }

    @Test func workingDirectoryIsEmptiedBeforeRun() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: work.appending(path: "stale.txt"))
        try FileManager.default.createDirectory(at: work.appending(path: "sub"), withIntermediateDirectories: true)
        let claude = try FakeClaude.make(in: dir, responses: [success(title: "t")])
        _ = try await summarizer(claude, work: work).summarize(input())
        #expect(try FakeClaude.listing(in: dir, call: 1).isEmpty)
    }

    @Test func notLoggedInStopsBeforeSummarizing() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work")
        let claude = try FakeClaude.make(in: dir, auth: #"{"loggedIn":false}"#, responses: [success(title: "t")])
        let e = await failure { try await summarizer(claude, work: work).summarize(input()) }
        #expect(e == .notLoggedIn)
        #expect(FakeClaude.count(in: dir) == 0)

        let notJSON = try FakeClaude.make(in: dir.appending(path: "b"), auth: "not json", responses: [success(title: "t")])
        let e2 = await failure { try await summarizer(notJSON, work: work).summarize(input()) }
        #expect(e2 == .notLoggedIn)

        let missing = dir.appending(path: "missing/claude")
        let e3 = await failure { try await summarizer(missing, work: work).summarize(input()) }
        #expect(e3 == .claudeNotFound(path: missing.path(percentEncoded: false)))
    }

    @Test func isLoggedInRequiresZeroExitAndTrue() {
        func r(_ s: String, exit: Int32 = 0) -> ProcessResult {
            ProcessResult(exitCode: exit, stdout: Data(s.utf8), stderr: Data(), timedOut: false)
        }
        #expect(ClaudeResultClassifier.isLoggedIn(r(#"{"loggedIn":true,"authMethod":"claude.ai"}"#)))
        #expect(!ClaudeResultClassifier.isLoggedIn(r(#"{"loggedIn":true}"#, exit: 1)))
        #expect(!ClaudeResultClassifier.isLoggedIn(r(#"{"loggedIn":false}"#)))
        #expect(!ClaudeResultClassifier.isLoggedIn(r(#"{}"#)))
        #expect(!ClaudeResultClassifier.isLoggedIn(r("nope")))
    }

    @Test(arguments: [
        (#"{"is_error":true,"subtype":"success","result":"You've hit your limit · resets 3pm"}"#, "rateLimited"),
        (#"{"is_error":true,"subtype":"success","result":"Prompt is too long"}"#, "contextExceeded"),
        (#"{"is_error":true,"subtype":"success","result":"Not logged in · Please run /login"}"#, "notLoggedIn"),
        (#"{"is_error":false,"subtype":"error_max_turns"}"#, "invalidOutput"),
        (#"{"is_error":false,"subtype":"success","structured_output":{"title":1}}"#, "invalidOutput"),
        ("not json", "failed"),
    ]) func classifiesFailures(stdout: String, expected: String) {
        let result = ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data(), timedOut: false)
        guard case .failure(let e) = ClaudeResultClassifier.classify(result) else {
            Issue.record("expected failure \(expected)")
            return
        }
        #expect(caseName(e) == expected)
    }

    @Test func classifierUsesStderrAndOrder() {
        func classify(_ out: String, _ err: String, exit: Int32 = 1, timedOut: Bool = false) -> Result<MinutesOutput, SummarizerError> {
            ClaudeResultClassifier.classify(ProcessResult(exitCode: exit, stdout: Data(out.utf8), stderr: Data(err.utf8), timedOut: timedOut))
        }
        #expect(classify("", "API Error: rate_limit_error") == .failure(.rateLimited(message: "API Error: rate_limit_error")))
        #expect(classify("", "Invalid API key · Fix external API key") == .failure(.notLoggedIn))
        #expect(classify(success(title: "t"), "", exit: 0, timedOut: true) == .failure(.timedOut))
        let long = String(repeating: "e", count: 600)
        #expect(classify("secret stdout body", long, exit: 3) == .failure(.failed(exitCode: 3, message: String(long.prefix(500)))))
        guard case .success(let out) = classify(success(title: "ok"), "", exit: 0) else {
            Issue.record("expected success"); return
        }
        #expect(out.title == "ok")
    }

    @Test func timeoutIsTimedOut() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work")
        let claude = try FakeClaude.make(in: dir, responses: [success(title: "t")], sleepSeconds: 5)
        let e = await failure { try await summarizer(claude, work: work, timeout: .seconds(1)).summarize(input()) }
        #expect(e == .timedOut)
    }

    @Test func contextExceededRetriesOnceWithSplit() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work")
        let claude = try FakeClaude.make(in: dir, responses: [
            Self.tooLong, success(title: "部1"), success(title: "部2"), success(title: "統合"),
        ])
        let out = try await summarizer(claude, work: work).summarize(input())
        #expect(out.title == "統合")
        #expect(FakeClaude.count(in: dir) == 4)
        #expect(try FakeClaude.stdin(in: dir, call: 2).contains(DefaultPrompt.partNote(index: 1, count: 2)))
        #expect(try FakeClaude.stdin(in: dir, call: 3).contains(DefaultPrompt.partNote(index: 2, count: 2)))
        let merge = try FakeClaude.stdin(in: dir, call: 4)
        #expect(merge.contains(DefaultPrompt.mergeInstructions))
        #expect(merge.contains("部1") && merge.contains("部2"))
    }

    @Test func contextExceededTwiceFails() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work")
        let claude = try FakeClaude.make(in: dir, responses: [Self.tooLong])
        let e = await failure { try await summarizer(claude, work: work).summarize(input()) }
        #expect(e.map(caseName) == "contextExceeded")
        #expect(FakeClaude.count(in: dir) == 2)
    }

    @Test func splitPlanRunsPartsThenMerge() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work")
        let big = input(190, chars: 1_000)
        guard case .split(let parts) = PromptBuilder().plan(big) else { Issue.record("expected split"); return }
        #expect(parts.count == 2)
        let claude = try FakeClaude.make(in: dir, responses: [success(title: "A"), success(title: "B"), success(title: "M")])
        let out = try await summarizer(claude, work: work).summarize(big)
        #expect(out.title == "M")
        #expect(FakeClaude.count(in: dir) == 3)
        #expect(try FakeClaude.stdin(in: dir, call: 1) == parts[0])
        #expect(try FakeClaude.stdin(in: dir, call: 2) == parts[1])
        #expect(try FakeClaude.stdin(in: dir, call: 3).contains(DefaultPrompt.mergeInstructions))
    }

    @Test func failedPartStopsBeforeMerge() async throws {
        let dir = try tempDir(), work = dir.appending(path: "work")
        let claude = try FakeClaude.make(in: dir, responses: [
            success(title: "A"), #"{"is_error":true,"subtype":"success","result":"You've hit your limit"}"#,
        ])
        let e = await failure { try await summarizer(claude, work: work).summarize(input(190, chars: 1_000)) }
        #expect(e.map(caseName) == "rateLimited")
        #expect(FakeClaude.count(in: dir) == 2)
    }
}
