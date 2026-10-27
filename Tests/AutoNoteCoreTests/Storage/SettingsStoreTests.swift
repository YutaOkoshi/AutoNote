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
