import Testing
import Foundation
@testable import AutoNoteCore

/// `Settings.changedKeys(from:to:)`: the JSON key names of what a save changed, for the log (values never logged).
@Suite struct SettingsChangedKeysTests {
    @Test func nothingChanged() {
        #expect(Settings.changedKeys(from: Settings(), to: Settings()) == [])
    }

    /// The two keys changed at 11:59 on 2026-10-30, in `settings.json` spelling and sorted.
    @Test func reportsJSONKeyNamesSorted() {
        var old = Settings()
        old.finalModel = "large-v3-turbo"
        var new = old
        new.finalModel = "large-v3-turbo-q5_0"
        new.liveSummaryEnabled = true
        #expect(Settings.changedKeys(from: old, to: new) == ["final_model", "live_summary_enabled"])
    }

    /// A key that appears or disappears (an optional set or cleared) counts as changed.
    @Test func optionalSetAndCleared() {
        var old = Settings()
        old.outputFolder = "/Fictional/Vault"
        var new = Settings()
        new.liveEngine = "apple"
        #expect(Settings.changedKeys(from: old, to: new) == ["live_engine", "output_folder"])
    }

    /// Nested objects name the inner key.
    @Test func nestedShortcut() {
        var new = Settings()
        new.shortcuts.toggleRecording = "ctrl+option+t"
        #expect(Settings.changedKeys(from: Settings(), to: new) == ["shortcuts.toggle_recording"])
    }
}

@Suite struct SettingsChangedKeysClaudeLaunchTests {
    /// Both new keys are reported by name; a variable's name (like its value) never reaches the log.
    @Test func claudeArgsAndEnvAreReportedWithoutTheirContents() {
        var new = Settings()
        new.claudeArgs = ["--settings", "/Fictional/s.json"]
        new.claudeEnv = ["CLAUDE_CONFIG_DIR": "/Fictional/c"]
        #expect(Settings.changedKeys(from: Settings(), to: new) == ["claude_args", "claude_env"])
        var changed = new
        changed.claudeEnv["CLAUDE_CONFIG_DIR"] = "/Fictional/d"
        #expect(Settings.changedKeys(from: new, to: changed) == ["claude_env"])
    }
}
