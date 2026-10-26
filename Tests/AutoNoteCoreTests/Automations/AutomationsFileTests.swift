import Foundation
import Testing
@testable import AutoNoteCore

private let specExample = """
[
  {
    "name": "Slack に要約を投稿",
    "enabled": true,
    "on": "minutes_generated",
    "command": "curl -s -X POST -d \\"$AUTONOTE_MINUTES_PATH\\" https://example.invalid/hook",
    "timeout_sec": 60
  },
  {
    "name": "Claude で Next Action を整理",
    "enabled": true,
    "on": "minutes_generated",
    "command": "claude -p \\"整理して\\" < \\"$AUTONOTE_MINUTES_PATH\\""
  }
]
"""

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("automations-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ text: String, mode: Int, name: String = "automations.json") throws -> URL {
    let url = try tempDir().appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    return url
}

private func mode(of url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite struct AutomationsFileTests {
    @Test func loadsSpecExample() throws {
        let r = AutomationsFile(url: try write(specExample, mode: 0o600)).load()
        #expect(r.items.map(\.definition.name) == ["Slack に要約を投稿", "Claude で Next Action を整理"])
        #expect(r.items.map(\.definition.timeoutSec) == [60, 300])
        #expect(r.items.allSatisfy { $0.isRunnable && $0.definition.on == .minutesGenerated })
        #expect(r.warnings.isEmpty && !r.disabledByPermission)
    }

    @Test func missingTimeoutDefaultsTo300() throws {
        let json = #"[{"name":"a","enabled":true,"on":"recording_started","command":"true"}]"#
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(r.items.first?.definition.timeoutSec == 300)
        #expect(r.items.first?.definition.on == .recordingStarted)
    }

    @Test func missingFileIsEmptyWithoutWarning() throws {
        let url = try tempDir().appendingPathComponent("automations.json")
        let r = AutomationsFile(url: url).load()
        #expect(r.items.isEmpty)
        #expect(r.warnings.isEmpty)
        #expect(!r.disabledByPermission)
    }

    @Test(arguments: [0o664, 0o646, 0o666])
    func writableByOthersDisablesAll(mode: Int) throws {
        let r = AutomationsFile(url: try write(specExample, mode: mode)).load()
        #expect(r.disabledByPermission && r.items.count == 2 && r.items.allSatisfy { !$0.isRunnable })
        #expect(r.items.allSatisfy { $0.problem == r.warnings.first })
        #expect(r.warnings == ["automations.json が自分以外から書き込める権限になっているため、Automations を無効にしました（chmod 600 で直せます）"])
    }

    @Test func invalidJSONWarnsAndDoesNotThrow() throws {
        let r = AutomationsFile(url: try write("[{", mode: 0o600)).load()
        #expect(r.items.isEmpty)
        #expect(r.warnings.count == 1)
        #expect(r.warnings.first?.hasPrefix("automations.json を読めません") == true)
    }

    @Test func unknownTriggerIsWarnedNotListed() throws {
        let json = """
        [{"name":"bad","enabled":true,"on":"meeting_ended","command":"true"},
         {"name":"good","enabled":true,"on":"transcript_only","command":"true"}]
        """
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(r.items.map(\.definition.name) == ["good"])
        #expect(r.items[0].isRunnable && r.items[0].problem == nil)
        #expect(r.warnings == ["entries[0]: きっかけ meeting_ended は使えません"])
    }

    @Test func missingNameIsWarnedNotListed() throws {
        let json = #"[{"enabled":true,"on":"minutes_generated","command":"true"}]"#
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(r.items.isEmpty)
        #expect(r.warnings == ["entries[0]: name がありません"])
    }

    @Test func nonObjectIsWarnedNotListed() throws {
        let json = #"[{"name":"ok","on":"minutes_generated","command":"true"}, 42]"#
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(r.items.map(\.definition.name) == ["ok"])
        #expect(r.warnings == ["entries[1]: オブジェクトではありません"])
    }

    @Test func nonBoolEnabledAndNonNumberTimeoutAreWarned() throws {
        let json = """
        [{"name":"a","enabled":"false","on":"minutes_generated","command":"true"},
         {"name":"b","on":"minutes_generated","command":"true","timeout_sec":"9"}]
        """
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(r.items.isEmpty)
        #expect(r.warnings.count == 2)
    }

    @Test func brokenEntriesSurviveSave() throws {
        let json = """
        [{"name":"bad","enabled":true,"on":"meeting_ended","command":"rm -rf x"},
         {"name":"good","enabled":true,"on":"transcript_only","command":"true"}]
        """
        let file = AutomationsFile(url: try write(json, mode: 0o600))
        let first = file.load()
        try file.save(first.items.map(\.definition))
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("meeting_ended") && text.contains("rm -rf x"))
        #expect(!text.contains("minutes_generated"))
        let second = file.load()
        // Broken entries are appended after the valid ones, so only the index moves.
        #expect(first.warnings == ["entries[0]: きっかけ meeting_ended は使えません"])
        #expect(second.warnings == ["entries[1]: きっかけ meeting_ended は使えません"])
        #expect(second.items == first.items)
    }

    @Test func importReplacingKeepsEveryEntry() throws {
        let json = #"[{"name":"bad","on":"nope","command":"true"},{"name":"g","on":"minutes_generated","command":"true"}]"#
        let src = try write(json, mode: 0o644, name: "src.json")
        let file = AutomationsFile(url: try tempDir().appendingPathComponent("automations.json"))
        let r = try file.importReplacing(from: src)
        #expect(try Data(contentsOf: file.url) == Data(contentsOf: src))
        #expect(r.items.map(\.definition.name) == ["g"])
        #expect(r.warnings == ["entries[0]: きっかけ nope は使えません"])
        #expect(try mode(of: file.url) == 0o600)
    }

    @Test func duplicateNameMarksSecond() throws {
        let json = """
        [{"name":"dup","enabled":true,"on":"minutes_generated","command":"true"},
         {"name":"dup","enabled":true,"on":"minutes_generated","command":"true"}]
        """
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(r.items[0].isRunnable && r.items[0].problem == nil)
        #expect(!r.items[1].isRunnable)
        #expect(r.items[1].problem == "同じ名前の Automation が先にあります")
    }

    @Test func disabledEntryIsNotRunnableWithoutProblem() throws {
        let json = #"[{"name":"off","enabled":false,"on":"minutes_generated","command":"true"}]"#
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(!r.items[0].isRunnable && r.items[0].problem == nil)
    }

    @Test func emptyCommandAndBadTimeoutAreProblems() throws {
        let json = """
        [{"name":"e","enabled":true,"on":"minutes_generated","command":"  "},
         {"name":"t","enabled":true,"on":"minutes_generated","command":"true","timeout_sec":0}]
        """
        let r = AutomationsFile(url: try write(json, mode: 0o600)).load()
        #expect(!r.items[0].isRunnable && r.items[0].problem != nil)
        #expect(!r.items[1].isRunnable && r.items[1].problem != nil)
    }

    @Test func saveWrites0600AndRoundTrips() throws {
        let url = try tempDir().appendingPathComponent("automations.json")
        let defs = [
            AutomationDefinition(name: "a", enabled: true, on: .recordingStopped, command: "echo hi", timeoutSec: 30),
            AutomationDefinition(name: "b", enabled: false, on: .transcriptOnly, command: "true"),
        ]
        let file = AutomationsFile(url: url)
        try file.save(defs)
        #expect(try mode(of: url) == 0o600)
        let r = file.load()
        #expect(r.items.map(\.definition) == defs)
        #expect(r.warnings.isEmpty)
    }

    @Test func importReplacingValidatesFirst() throws {
        let url = try write(specExample, mode: 0o600)
        let file = AutomationsFile(url: url)
        let before = try Data(contentsOf: url)
        let bad = try write("[{", mode: 0o600, name: "bad.json")
        #expect(throws: (any Error).self) { try file.importReplacing(from: bad) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func exportAndImportRoundTrip() throws {
        let src = AutomationsFile(url: try write(specExample, mode: 0o600))
        let out = try tempDir().appendingPathComponent("export.json")
        try src.export(to: out)
        let dst = AutomationsFile(url: try tempDir().appendingPathComponent("automations.json"))
        let r = try dst.importReplacing(from: out)
        #expect(r.items.map(\.definition) == src.load().items.map(\.definition))
        #expect(try mode(of: dst.url) == 0o600)
    }
}
