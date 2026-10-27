import Foundation
import Testing
@testable import AutoNoteCore

private let cwd = URL(filePath: "/Users/x/work")

private func inv(_ c: IPCCommand, json: Bool = false, args: IPCArgs = IPCArgs()) -> CLIInvocation {
    CLIInvocation(command: c, args: args, json: json)
}

@Suite struct CLITests {
    // Every command parses to the expected invocation; --json may appear anywhere; import paths are absolute.
    @Test func parsesEveryCommand() throws {
        #expect(try CLIParser.parse(["start", "--lang", "en"], cwd: cwd) == .invocation(.init(command: .start, args: IPCArgs(lang: .en), json: false)))
        #expect(try CLIParser.parse(["start"], cwd: cwd) == .invocation(.init(command: .start, args: IPCArgs(), json: false)))
        #expect(try CLIParser.parse(["stop"], cwd: cwd) == .invocation(inv(.stop)))
        #expect(try CLIParser.parse(["pause"], cwd: cwd) == .invocation(inv(.pause)))
        #expect(try CLIParser.parse(["resume"], cwd: cwd) == .invocation(inv(.resume)))
        #expect(try CLIParser.parse(["bookmark"], cwd: cwd) == .invocation(inv(.bookmark)))
        #expect(try CLIParser.parse(["bookmark", "大事", "な点"], cwd: cwd) == .invocation(.init(command: .bookmark, args: IPCArgs(note: "大事 な点"), json: false)))
        #expect(try CLIParser.parse(["status"], cwd: cwd) == .invocation(inv(.status)))
        #expect(try CLIParser.parse(["status", "--json"], cwd: cwd) == .invocation(inv(.status, json: true)))
        #expect(try CLIParser.parse(["list", "--json", "--since", "2026-10-01"], cwd: cwd) == .invocation(.init(command: .list, args: IPCArgs(since: "2026-10-01"), json: true)))
        #expect(try CLIParser.parse(["latest", "--open"], cwd: cwd) == .invocation(.init(command: .latest, args: IPCArgs(open: true), json: false)))
        #expect(try CLIParser.parse(["latest"], cwd: cwd) == .invocation(inv(.latest)))
        #expect(try CLIParser.parse(["import", "録音 1.m4a"], cwd: cwd) == .invocation(.init(command: .import, args: IPCArgs(file: "/Users/x/work/録音 1.m4a"), json: false)))
        #expect(try CLIParser.parse(["import", "/a/../b/c.m4a"], cwd: cwd) == .invocation(.init(command: .import, args: IPCArgs(file: "/b/c.m4a"), json: false)))
        #expect(try CLIParser.parse(["regenerate", "20261024-1400-a1b2"], cwd: cwd) == .invocation(.init(command: .regenerate, args: IPCArgs(meetingID: "20261024-1400-a1b2"), json: false)))
        #expect(try CLIParser.parse(["automations", "list"], cwd: cwd) == .invocation(inv(.automationsList)))
        #expect(try CLIParser.parse(["automations", "run", "Slack に要約を投稿", "20261024-1400-a1b2"], cwd: cwd) == .invocation(.init(command: .automationsRun, args: IPCArgs(meetingID: "20261024-1400-a1b2", name: "Slack に要約を投稿"), json: false)))
    }

    // --version, help forms and the dev passthrough are recognised.
    @Test func versionHelpAndDev() throws {
        #expect(try CLIParser.parse(["--version"], cwd: cwd) == .version)
        #expect(try CLIParser.parse(["--help"], cwd: cwd) == .help)
        #expect(try CLIParser.parse(["-h"], cwd: cwd) == .help)
        #expect(try CLIParser.parse(["help"], cwd: cwd) == .help)
        #expect(try CLIParser.parse(["dev", "render-fixture", "--out", "/tmp/o"], cwd: cwd) == .dev(["render-fixture", "--out", "/tmp/o"]))
    }

    // Bad argument shapes throw CLIUsageError.
    @Test(arguments: [[], ["--json"], ["--json", "--json"], ["start", "--lang", "fr"], ["regenerate"], ["automations", "run", "x"], ["frobnicate"], ["stop", "extra"]] as [[String]])
    func usageErrors(argv: [String]) {
        #expect(throws: CLIUsageError.self) { try CLIParser.parse(argv, cwd: cwd) }
    }

    // Usage error: exit 1, Japanese message first, then the usage text on stderr.
    @Test func usageErrorExitCode() {
        let out = CLIRenderer.render(CLIUsageError(message: "知らないコマンドです: frobnicate"))
        #expect(out.exitCode == 1)
        #expect(out.stdout == "")
        #expect(out.stderr.hasPrefix("エラー: 知らないコマンドです: frobnicate\n"))
        #expect(out.stderr.contains("usage: autonote start"))
        #expect(!CLIRenderer.usage.contains("dev"))
    }

    // Status human text for idle, and JSON prints only the result on one line.
    @Test func statusHumanAndJSON() throws {
        let r = IPCResponse.success(1, IPCResult(status: StatusResult(recorder: .init(state: "idle"), queue: [], outputFolderAvailable: true)))
        #expect(CLIRenderer.render(r, for: inv(.status)).stdout == "録音器: 待機\n待ち行列: なし\n")
        let j = CLIRenderer.render(r, for: inv(.status, json: true))
        #expect(j.exitCode == 0 && j.stdout.contains(#""state":"idle""#))
        #expect(j.stdout.hasSuffix("\n") && j.stdout.dropLast().firstIndex(of: "\n") == nil)
        #expect(!j.stdout.contains(#""ok""#))
    }

    // Recording line, queue line, retry/confirmation/failed labels and missing output folder.
    @Test func statusRecordingHuman() {
        let queue = [
            QueueItemDTO(meetingID: "20261024-1400-a1b2", stage: "transcribe", state: "running", progress: 0.42, label: "文字起こし中 42%"),
            QueueItemDTO(meetingID: "m2", stage: "summarize", state: "waiting", label: "議事録生成中", notBefore: Date(timeIntervalSince1970: 5)),
            QueueItemDTO(meetingID: "m3", stage: "write_vault", state: "awaitingConfirmation", label: "x", awaitingConfirmation: true),
            QueueItemDTO(meetingID: "m4", stage: "summarize", state: "failed", label: "x", message: "claude が見つかりません"),
        ]
        let r = IPCResponse.success(1, IPCResult(status: StatusResult(
            recorder: .init(state: "recording", elapsedSeconds: 754, device: "Jabra"), queue: queue, outputFolderAvailable: false)))
        let text = CLIRenderer.render(r, for: inv(.status)).stdout
        #expect(text.hasPrefix("録音器: 録音中 00:12:34（Jabra）\n"))
        #expect(text.contains("  20261024-1400-a1b2  文字起こし中 42%\n"))
        #expect(text.contains("  m2  再試行待ち\n"))
        #expect(text.contains("  m3  上書きの確認待ち\n"))
        #expect(text.contains("  m4  失敗: claude が見つかりません\n"))
        #expect(text.hasSuffix("出力フォルダが見つかりません\n"))
    }

    // Error responses: human to stderr, JSON error object to stdout, both exit 1.
    @Test func errorResponse() {
        let e = IPCResponse.failure(2, IPCError(code: .notRecording, message: "録音中ではありません"))
        #expect(CLIRenderer.render(e, for: inv(.bookmark)) == CLIOutput(stdout: "", stderr: "エラー: 録音中ではありません\n", exitCode: 1))
        #expect(CLIRenderer.render(e, for: inv(.bookmark, json: true)) == CLIOutput(stdout: #"{"error":{"code":"not_recording","message":"録音中ではありません"}}"# + "\n", stderr: "", exitCode: 1))
    }

    // Client errors map to Japanese copy, timeout shows the seconds actually used, exit 1.
    @Test func clientErrors() {
        #expect(CLIRenderer.render(SocketClientError.timedOut, json: false) == CLIOutput(stdout: "", stderr: "エラー: AutoNote が 10 秒以内に応答しませんでした\n", exitCode: 1))
        #expect(CLIRenderer.render(SocketClientError.timedOut, json: false, timeoutSeconds: 30).stderr == "エラー: AutoNote が 30 秒以内に応答しませんでした\n")
        #expect(CLIRenderer.render(SocketClientError.appNotRunning, json: false) == CLIOutput(stdout: "", stderr: "エラー: AutoNote が起動していません\n", exitCode: 1))
        #expect(CLIRenderer.render(SocketClientError.launchFailed("m"), json: false) == CLIOutput(stdout: "", stderr: "エラー: AutoNote を起動できませんでした: m\n", exitCode: 1))
        let j = CLIRenderer.render(SocketClientError.appNotRunning, json: true)
        #expect(j.exitCode == 1 && j.stdout.hasPrefix(#"{"error":{"#) && j.stderr == "")
    }

    // List line format and all state words.
    @Test func listHuman() throws {
        let tz = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let start = Date(timeIntervalSince1970: 1_792_818_000) // 2026-10-24 14:00 JST
        func row(_ s: MeetingRowState, id: String = "20261024-1400-a1b2", label: String? = nil) -> MeetingRow {
            MeetingRow(id: id, title: "プロジェクト定例", startedAt: start, durationMinutes: 62, state: s, progressLabel: label)
        }
        func text(_ r: MeetingRow) -> String {
            CLIRenderer.render(.success(1, IPCResult(meetings: [r])), for: inv(.list), timeZone: tz).stdout
        }
        #expect(text(row(.minutesGenerated)) == "2026-10-24 14:00  62 分  プロジェクト定例  完了  20261024-1400-a1b2\n")
        #expect(text(row(.recording)).contains("  録音中  "))
        #expect(text(row(.processing, label: "文字起こし中 42%")).contains("  文字起こし中 42%  "))
        #expect(text(row(.transcriptOnly)).contains("  議事録 未生成  "))
        #expect(text(row(.failed)).contains("  失敗  "))
        #expect(text(row(.tooShort)).contains("  短すぎる録音  "))
        #expect(text(row(.recorded)).contains("  録音済み  "))
        // I3: 応答待ちは仕事の長さに合わせる。import は 24 時間、automations run は定義の上限 + kill の猶予 + 30 秒
        #expect(CLIInvocation(command: .import).responseTimeoutSeconds == 86_400)
        #expect(CLIInvocation(command: .automationsRun).responseTimeoutSeconds
            == AutomationDefinition.timeoutRange.upperBound + AutomationRunner.defaultKillGraceSeconds + 30)
        #expect(CLIInvocation(command: .automationsRun).responseTimeoutSeconds == 86_435)
        #expect(CLIInvocation(command: .stop).responseTimeoutSeconds == 30)
        #expect(CLIInvocation(command: .list).responseTimeoutSeconds == 10)
        #expect(MeetingRowState.minutesGenerated.displayText(progressLabel: nil) == "完了")
        #expect(CLIRenderer.render(.success(1, IPCResult(meetings: [])), for: inv(.list)).stdout == "")
    }

    // latest prints only the path; import/regenerate acknowledge; automations render as specified.
    @Test func otherCommandsHuman() {
        #expect(CLIRenderer.render(.success(1, IPCResult(path: "/v/m.md")), for: inv(.latest)).stdout == "/v/m.md\n")
        #expect(CLIRenderer.render(.success(1, IPCResult(meetingID: "abc")), for: inv(.import)).stdout == "受け付けました: abc\n")
        #expect(CLIRenderer.render(.success(1, IPCResult(meetingID: "abc")), for: inv(.regenerate)).stdout == "受け付けました: abc\n")
        let list = IPCResult(automations: [
            AutomationSummary(name: "Slack", on: .minutesGenerated, enabled: true, isRunnable: true),
            AutomationSummary(name: "Bad", on: .recordingStopped, enabled: false, isRunnable: false, problem: "コマンドがありません"),
        ])
        #expect(CLIRenderer.render(.success(1, list), for: inv(.automationsList)).stdout
                == "Slack  minutes_generated  有効\nBad  recording_stopped  無効（コマンドがありません）\n")
        func run(code: Int32?, timedOut: Bool) -> CLIOutput {
            let rec = AutomationRunRecord(name: "Slack", event: .minutesGenerated, meetingID: "m", startedAt: Date(timeIntervalSince1970: 0),
                                          durationSeconds: 1.5, exitCode: code, timedOut: timedOut, skippedReason: nil, logDirectory: "/logs/x")
            return CLIRenderer.render(.success(1, IPCResult(run: rec)), for: inv(.automationsRun))
        }
        #expect(run(code: 0, timedOut: false) == CLIOutput(stdout: "終了コード 0（1.5 秒）ログ: /logs/x\n", stderr: "", exitCode: 0))
        #expect(run(code: 2, timedOut: false).exitCode == 2)
        let t = run(code: nil, timedOut: true)
        // --json carries the same exit code.
        func runJSON(code: Int32?, timedOut: Bool) -> Int32 {
            let rec = AutomationRunRecord(name: "S", event: .minutesGenerated, meetingID: "m", startedAt: Date(timeIntervalSince1970: 0),
                                          durationSeconds: 1, exitCode: code, timedOut: timedOut, skippedReason: nil, logDirectory: "/l")
            return CLIRenderer.render(.success(1, IPCResult(run: rec)), for: inv(.automationsRun, json: true)).exitCode
        }
        #expect(runJSON(code: 0, timedOut: false) == 0)
        #expect(runJSON(code: 3, timedOut: false) == 3)
        #expect(runJSON(code: nil, timedOut: true) == 1)
        #expect(t.stdout == "タイムアウトしました（1.5 秒）ログ: /logs/x\n" && t.exitCode == 1)
    }
}
