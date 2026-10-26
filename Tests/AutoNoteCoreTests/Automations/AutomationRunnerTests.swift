import Darwin
import Foundation
import Testing
@testable import AutoNoteCore

private struct Fixture {
    let root: URL
    var logs: URL { root.appending(path: "logs") }
    var ledger: URL { root.appending(path: "automation-ledger.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "an-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func runner(killGrace: Duration = .seconds(5), maxLogRuns: Int = 200, ledgerFile: URL? = nil,
                shell: [String] = ["/bin/zsh", "-fc"]) -> AutomationRunner {
        AutomationRunner(logsDirectory: logs, ledgerFile: ledgerFile ?? ledger, shell: shell,
                         killGrace: killGrace, maxLogRuns: maxLogRuns)
    }
}

private let ctx = AutomationContext(
    event: .minutesGenerated,
    meetingID: MeetingID(rawValue: "20261024-1400-a1b2"),
    file: URL(filePath: "/tmp/x/2026-10-24_1400_定例.md"),
    title: "定例",
    date: "2026-10-24",
    start: "14:00",
    minutesJSON: URL(filePath: "/tmp/x/minutes.json"))

private func def(_ command: String, name: String = "テスト automation", timeout: Int = 20) -> AutomationDefinition {
    AutomationDefinition(name: name, on: .minutesGenerated, command: command, timeoutSec: timeout)
}

private func stdout(_ rec: AutomationRunRecord) throws -> String {
    try String(contentsOf: URL(filePath: rec.logDirectory).appending(path: "stdout.txt"), encoding: .utf8)
}

private func readPID(_ url: URL) throws -> pid_t {
    let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(pid_t(text))
}

/// SIGKILL delivery and reaping are asynchronous; poll up to 2 s.
private func isGone(_ pid: pid_t) async -> Bool {
    for _ in 0..<40 {
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func logFolders(_ fx: Fixture) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: fx.logs, includingPropertiesForKeys: nil)
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

@Suite struct AutomationRunnerTests {
    @Test func defaultShellIsZshLogin() {
        #expect(AutomationRunner.defaultShell == ["/bin/zsh", "-lc"])
    }

    @Test func passesEnvironmentAndStdin() async throws {
        let fx = try Fixture()
        let runner = fx.runner()
        let rec = await runner.run(def(#"printf '%s\n' "$AUTONOTE_EVENT" "$AUTONOTE_MEETING_ID" "$AUTONOTE_FILE" "$AUTONOTE_TITLE" "$AUTONOTE_DATE" "$AUTONOTE_START" "$AUTONOTE_JSON"; cat"#),
                                   context: ctx, dedupeKey: nil)
        let out = try stdout(rec)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.prefix(7) == ["minutes_generated", "20261024-1400-a1b2", "/tmp/x/2026-10-24_1400_定例.md", "定例", "2026-10-24", "14:00", "/tmp/x/minutes.json"])
        let json = lines.dropFirst(7).joined(separator: "\n")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(obj.keys) == ["event", "meeting_id", "file", "title", "date", "start", "json"])
        #expect(obj["event"] as? String == "minutes_generated")
        #expect(obj["meeting_id"] as? String == "20261024-1400-a1b2")
        #expect(obj["file"] as? String == "/tmp/x/2026-10-24_1400_定例.md")
        #expect(obj["title"] as? String == "定例")
        #expect(obj["date"] as? String == "2026-10-24")
        #expect(obj["start"] as? String == "14:00")
        #expect(obj["json"] as? String == "/tmp/x/minutes.json")
        #expect(rec.exitCode == 0 && rec.succeeded)
        #expect(rec.name == "テスト automation" && rec.event == .minutesGenerated && rec.meetingID == "20261024-1400-a1b2")
    }

    @Test func absentFileAndJSONAreEmptyEnvAndNullJSON() async throws {
        var c = ctx
        c.file = nil
        c.minutesJSON = nil
        #expect(c.environment()["AUTONOTE_FILE"] == "")
        #expect(c.environment()["AUTONOTE_JSON"] == "")
        let fx = try Fixture()
        let rec = await fx.runner().run(def(#"printf '[%s][%s]\n' "$AUTONOTE_FILE" "$AUTONOTE_JSON"; cat"#), context: c, dedupeKey: nil)
        let out = try stdout(rec)
        #expect(out.hasPrefix("[][]\n"))
        let json = String(out.dropFirst("[][]\n".count))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["file"] is NSNull)
        #expect(obj["json"] is NSNull)
        #expect(rec.succeeded)
    }

    @Test func nonZeroExitIsFailure() async throws {
        let fx = try Fixture()
        let rec = await fx.runner().run(def("exit 3"), context: ctx, dedupeKey: nil)
        #expect(rec.exitCode == 3)
        #expect(!rec.succeeded && !rec.timedOut && rec.skippedReason == nil)
    }

    @Test func timeoutKillsWholeProcessGroup() async throws {
        let fx = try Fixture()
        let pidFile = fx.root.appending(path: "grandchild.pid")
        let rec = await fx.runner().run(def("sleep 30 & echo $! > \(pidFile.path); wait", timeout: 1), context: ctx, dedupeKey: nil)
        #expect(rec.timedOut && !rec.succeeded && rec.durationSeconds < 8)
        #expect(rec.exitCode == nil)
        #expect(await isGone(try readPID(pidFile)))
    }

    @Test func sigtermIgnoredIsKilled() async throws {
        let fx = try Fixture()
        let rec = await fx.runner(killGrace: .seconds(1)).run(def("trap '' TERM; sleep 30", timeout: 1), context: ctx, dedupeKey: nil)
        #expect(rec.timedOut && !rec.succeeded && rec.durationSeconds < 8)
        #expect(rec.exitCode == nil)
    }

    @Test func largeOutputDoesNotBlock() async throws {
        let fx = try Fixture()
        let rec = await fx.runner().run(def(#"head -c 300000 /dev/zero | tr '\0' a"#, timeout: 10), context: ctx, dedupeKey: nil)
        let size = try FileManager.default.attributesOfItem(atPath: URL(filePath: rec.logDirectory).appending(path: "stdout.txt").path)[.size] as? Int
        #expect(size == 300000)
        #expect(!rec.timedOut && rec.succeeded)
    }

    @Test func sameDedupeKeyRunsOnce() async throws {
        let fx = try Fixture()
        let counter = fx.root.appending(path: "counter.txt")
        let runner = fx.runner()
        let first = await runner.run(def("echo run >> \(counter.path)"), context: ctx, dedupeKey: "k1")
        let second = await runner.run(def("echo run >> \(counter.path)"), context: ctx, dedupeKey: "k1")
        #expect(first.succeeded && first.skippedReason == nil)
        #expect(second.skippedReason == "already_ran" && !second.succeeded)
        #expect(second.logDirectory == "")
        #expect(try String(contentsOf: counter, encoding: .utf8) == "run\n")
        #expect(try logFolders(fx).count == 1)
        #expect(await runner.recentRuns(limit: 10) == [first])
    }

    @Test func ledgerSurvivesNewRunner() async throws {
        let fx = try Fixture()
        let counter = fx.root.appending(path: "counter.txt")
        _ = await fx.runner().run(def("echo run >> \(counter.path)"), context: ctx, dedupeKey: "k1")
        let again = await fx.runner().run(def("echo run >> \(counter.path)"), context: ctx, dedupeKey: "k1")
        #expect(again.skippedReason == "already_ran" && again.logDirectory == "")
        #expect(try logFolders(fx).count == 1)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "run\n")
    }

    @Test func manualRunIgnoresLedger() async throws {
        let fx = try Fixture()
        let counter = fx.root.appending(path: "counter.txt")
        let runner = fx.runner()
        for _ in 0..<3 { _ = await runner.run(def("echo run >> \(counter.path)"), context: ctx, dedupeKey: nil) }
        #expect(try String(contentsOf: counter, encoding: .utf8) == "run\nrun\nrun\n")
    }

    @Test func keepsOnlyNewestLogRuns() async throws {
        let fx = try Fixture()
        let runner = fx.runner(maxLogRuns: 3)
        var recs: [AutomationRunRecord] = []
        for i in 0..<5 { recs.append(await runner.run(def("echo \(i)"), context: ctx, dedupeKey: nil)) }
        let folders = try logFolders(fx)
        #expect(folders.count == 3)
        let recent = await runner.recentRuns(limit: 10)
        #expect(recent.count == 3)
        #expect(recent.map(\.logDirectory) == recs.suffix(3).reversed().map(\.logDirectory))
    }

    @Test func resultJSONWritten() async throws {
        let fx = try Fixture()
        let rec = await fx.runner().run(def("echo hi"), context: ctx, dedupeKey: nil)
        let data = try Data(contentsOf: URL(filePath: rec.logDirectory).appending(path: "result.json"))
        #expect(try AutoNoteJSON.decoder().decode(AutomationRunRecord.self, from: data) == rec)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["meeting_id"] as? String == "20261024-1400-a1b2")
        #expect(obj["exit_code"] as? Int == 0 && obj["timed_out"] as? Bool == false && obj["started_at"] is String)
        #expect(URL(filePath: rec.logDirectory).lastPathComponent.hasSuffix("-20261024-1400-a1b2-automation"))
    }

    @Test func recordsStreamYieldsCompletedRuns() async throws {
        let fx = try Fixture()
        let runner = fx.runner()
        let a = await runner.records()
        let b = await runner.records()
        _ = await runner.run(def("true"), context: ctx, dedupeKey: "k1")
        _ = await runner.run(def("true"), context: ctx, dedupeKey: "k1")   // already_ran: not yielded
        let rec = await runner.run(def("exit 1"), context: ctx, dedupeKey: nil)
        var ia = a.makeAsyncIterator(), ib = b.makeAsyncIterator()
        #expect(await ia.next()?.skippedReason == nil)
        #expect(await ia.next() == rec)
        #expect(await ib.next()?.skippedReason == nil)
        #expect(await ib.next() == rec)
    }

    @Test func ledgerWriteFailureDoesNotRun() async throws {
        let fx = try Fixture()
        let counter = fx.root.appending(path: "counter.txt")
        let regularFile = fx.root.appending(path: "not-a-dir")
        try Data("x".utf8).write(to: regularFile)
        let runner = fx.runner(ledgerFile: regularFile.appending(path: "ledger.json"))
        let stream = await runner.records()
        let rec = await runner.run(def("echo run >> \(counter.path)"), context: ctx, dedupeKey: "k1")
        #expect(!rec.succeeded && rec.skippedReason == nil && rec.exitCode == nil && !rec.timedOut)
        #expect(rec.failureMessage?.contains("ledger") == true)
        #expect(!FileManager.default.fileExists(atPath: counter.path))
        let stderr = try String(contentsOf: URL(filePath: rec.logDirectory).appending(path: "stderr.txt"), encoding: .utf8)
        #expect(stderr.contains("ledger"))
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == rec)
    }

    @Test func corruptLedgerIsMovedAside() async throws {
        let fx = try Fixture()
        try Data("not json".utf8).write(to: fx.ledger)
        let rec = await fx.runner().run(def("true"), context: ctx, dedupeKey: "k1")
        #expect(rec.succeeded)
        let names = try FileManager.default.contentsOfDirectory(atPath: fx.root.path)
        let aside = try #require(names.first { $0.hasPrefix("automation-ledger.json.corrupt-") })
        #expect(try String(contentsOf: fx.root.appending(path: aside), encoding: .utf8) == "not json")
        #expect(aside.count == "automation-ledger.json.corrupt-".count + "yyyyMMdd-HHmmss".count)
        let keys = try AutoNoteJSON.decoder().decode([String].self, from: Data(contentsOf: fx.ledger))
        #expect(keys == ["k1"])
    }

    @Test func spawnFailureIsReportedAndRetryable() async throws {
        let fx = try Fixture()
        let broken = fx.runner(shell: ["/nonexistent/autonote-shell", "-c"])
        let stream = await broken.records()
        let rec = await broken.run(def("true"), context: ctx, dedupeKey: "k1")
        #expect(!rec.succeeded && rec.skippedReason == nil && rec.exitCode == nil && !rec.timedOut)
        #expect(rec.failureMessage != nil)
        let stderr = try String(contentsOf: URL(filePath: rec.logDirectory).appending(path: "stderr.txt"), encoding: .utf8)
        #expect(stderr.contains("/nonexistent/autonote-shell"))
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == rec)
        #expect(await broken.recentRuns(limit: 10) == [rec])
        let retry = await fx.runner().run(def("true"), context: ctx, dedupeKey: "k1")
        #expect(retry.succeeded && retry.skippedReason == nil)
    }
}
