import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

/// `claude_args` / `claude_env` in `settings.json`: the extra arguments and environment variables for every `claude` launch.
@Suite struct SettingsClaudeLaunchTests {
    @Test func defaultsAreEmpty() {
        let s = Settings()
        #expect(s.claudeArgs == [])
        #expect(s.claudeEnv == [:])
    }

    /// A file written before these keys existed still loads, with both empty.
    @Test func olderFileWithoutTheKeysLoads() throws {
        let s = try AutoNoteJSON.decoder().decode(Settings.self, from: Data(#"{"claude_path":"/opt/fake/claude"}"#.utf8))
        #expect(s.claudePath == "/opt/fake/claude")
        #expect(s.claudeArgs == [] && s.claudeEnv == [:])
    }

    /// Variable names keep their spelling through the snake-case key strategy.
    @Test func roundTripsThroughTheStore() async throws {
        let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
        let store = SettingsStore(paths: p)
        _ = try await store.update {
            $0.claudeArgs = ["--settings", "/Fictional/a b.json"]
            $0.claudeEnv = ["CLAUDE_CONFIG_DIR": "/Fictional/claude-work", "my_Var2": "x"]
        }
        let written = try String(contentsOf: p.settingsFile, encoding: .utf8)
        #expect(written.contains("\"claude_args\""))
        #expect(written.contains("\"claude_env\""))
        #expect(written.contains("\"CLAUDE_CONFIG_DIR\""))
        let loaded = try await SettingsStore(paths: p).load()
        #expect(loaded.claudeArgs == ["--settings", "/Fictional/a b.json"])
        #expect(loaded.claudeEnv == ["CLAUDE_CONFIG_DIR": "/Fictional/claude-work", "my_Var2": "x"])
    }

    /// A hand-edited file with an empty or invalid name loads without that entry.
    @Test func invalidNamesInTheFileAreDropped() throws {
        let json = #"{"claude_env":{"":"a","1BAD":"b","OK_1":"c","has space":"d"},"claude_args":["--x"]}"#
        let s = try AutoNoteJSON.decoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.claudeEnv == ["OK_1": "c"])
        #expect(s.claudeArgs == ["--x"])
    }

    @Test func environmentNameRule() {
        for ok in ["A", "_", "CLAUDE_CONFIG_DIR", "a1", "_x9"] { #expect(Settings.isValidEnvironmentName(ok), "\(ok)") }
        for bad in ["", "1A", "A-B", "A B", "Ａ", "A=B", "é"] { #expect(!Settings.isValidEnvironmentName(bad), "\(bad)") }
    }
}
