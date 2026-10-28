import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Test func partialSettingsAreFilledAndClamped() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
    #expect(try await SettingsStore(paths: p).load() == Settings())
    try Data(#"{"output_folder":"/v/Meetings","countdown_seconds":99,"disconnect_grace_seconds":1,"summarizer_kind":"claude_code","shortcuts":{"bookmark":"cmd+b"}}"#.utf8).write(to: p.settingsFile)
    let s = try await SettingsStore(paths: p).load()
    #expect(s.outputFolder == "/v/Meetings"); #expect(s.countdownSeconds == 30); #expect(s.disconnectGraceSeconds == 5); #expect(s.fillerRemoval)
    #expect(s.shortcuts.bookmark == "cmd+b"); #expect(s.shortcuts.toggleRecording == "ctrl+option+r"); #expect(s.shortcuts.togglePause == "ctrl+option+p")
    let store = SettingsStore(paths: p); let updated = try await store.update { $0.audioRetentionDays = 0 }
    #expect(try await store.load() == updated)
}

@Test func corruptSettingsAreSetAside() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
    try Data("{not json".utf8).write(to: p.settingsFile)
    let store = SettingsStore(paths: p, timeZone: Samples.tokyo)
    #expect(try await store.load() == Settings())
    let aside = try #require(await store.lastSetAside)
    #expect(aside.lastPathComponent.hasPrefix("settings.json.corrupt-"))
    #expect(aside.lastPathComponent.range(of: #"^settings\.json\.corrupt-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
    #expect(!FileManager.default.fileExists(atPath: p.settingsFile.path))
    #expect(FileManager.default.fileExists(atPath: aside.path))
}

@Test func changeReturnsOldAndNewInOneActorTurn() async throws {
    // 設定画面の保存は load→mutate→save を 1 回の actor ターンで行い、前後の値を返す（M2）
    let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
    let store = SettingsStore(paths: p)
    _ = try await store.update { $0.audioRetentionDays = 7 }
    let (old, new) = try await store.change { $0.audioRetentionDays = 30 }
    #expect(old.audioRetentionDays == 7 && new.audioRetentionDays == 30)
    #expect(try await store.load() == new)
}

@Test func firstRunCompletedReadsTheLegacyKeyAndWritesOnlyTheNewOne() async throws {
    // 旧キー consent_notice_shown（同意画面があった頃）を後方互換で読む。どちらかが true なら true。書き出しは新キーのみ
    let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
    let store = SettingsStore(paths: p)
    #expect(try await store.load().firstRunCompleted == false)
    for (json, expected) in [(#"{"consent_notice_shown":true}"#, true), (#"{"first_run_completed":true}"#, true),
                             (#"{"consent_notice_shown":false,"first_run_completed":true}"#, true),
                             (#"{"consent_notice_shown":true,"first_run_completed":false}"#, true),
                             (#"{"consent_notice_shown":false}"#, false)] {
        try Data(json.utf8).write(to: p.settingsFile)
        #expect(try await store.load().firstRunCompleted == expected, "\(json)")
    }
    try Data(#"{"consent_notice_shown":true}"#.utf8).write(to: p.settingsFile)
    _ = try await store.update { $0.audioRetentionDays = 7 }
    let written = try String(contentsOf: p.settingsFile, encoding: .utf8)
    #expect(written.contains("\"first_run_completed\""))
    #expect(!written.contains("consent_notice_shown"))
    #expect(try await store.load().firstRunCompleted)
}

@Test func liveSummaryDefaultsOff() throws {
    let s = Settings()
    #expect(!s.liveSummaryEnabled && s.liveSummaryIntervalSeconds == 20 && s.liveSummaryModel == "haiku")
    let json = try JSONSerialization.jsonObject(with: AutoNoteJSON.encoder().encode(s)) as? [String: Any]
    #expect(json?["live_summary_enabled"] as? Bool == false)
    #expect(json?["live_summary_interval_seconds"] as? Int == 20)
    #expect(json?["live_summary_model"] as? String == "haiku")
}

@Test func liveSummaryKeysAreReadAndClamped() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
    let store = SettingsStore(paths: p)
    func load(_ json: String) async throws -> Settings {
        try Data(json.utf8).write(to: p.settingsFile)
        return try await store.load()
    }
    var s = try await load(#"{"live_summary_enabled":true,"live_summary_interval_seconds":5,"live_summary_model":"sonnet"}"#)
    #expect(s.liveSummaryEnabled == true); #expect(s.liveSummaryIntervalSeconds == 10); #expect(s.liveSummaryModel == "sonnet")
    s = try await load(#"{"live_summary_interval_seconds":500,"live_summary_model":"  "}"#)
    #expect(s.liveSummaryIntervalSeconds == 120); #expect(s.liveSummaryModel == "haiku")
    s = try await load(#"{"live_summary_model":"  opus \n"}"#)
    #expect(s.liveSummaryModel == "opus")
    s = try await load(#"{"output_folder":"/v/Meetings"}"#)
    #expect(!s.liveSummaryEnabled); #expect(s.liveSummaryIntervalSeconds == 20); #expect(s.liveSummaryModel == "haiku")
    // Round trip through the store writes the snake_case keys.
    _ = try await store.update { $0.liveSummaryEnabled = true; $0.liveSummaryIntervalSeconds = 45; $0.liveSummaryModel = "sonnet" }
    let written = try String(contentsOf: p.settingsFile, encoding: .utf8)
    #expect(written.contains("\"live_summary_enabled\""))
    #expect(written.contains("\"live_summary_interval_seconds\""))
    #expect(written.contains("\"live_summary_model\""))
    let back = try await store.load()
    #expect(back.liveSummaryEnabled && back.liveSummaryIntervalSeconds == 45 && back.liveSummaryModel == "sonnet")
}

@Test func liveSummaryIntervalSetterClamps() {
    var s = Settings()
    s.liveSummaryIntervalSeconds = 9; #expect(s.liveSummaryIntervalSeconds == 10)
    s.liveSummaryIntervalSeconds = 121; #expect(s.liveSummaryIntervalSeconds == 120)
    s.liveSummaryIntervalSeconds = 30; #expect(s.liveSummaryIntervalSeconds == 30)
    #expect(Settings.liveSummaryIntervalRange == 10...120)
}
