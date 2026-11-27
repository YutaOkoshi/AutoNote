import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

/// A `settings.json` value AutoNote does not use is written to the log, once, with what is used instead.
@Suite struct SettingsDiagnosticsTests {
    private func recorder() -> (SettingsDiagnostics, LockedBox<[String]>) {
        let lines = LockedBox<[String]>([])
        return (SettingsDiagnostics(sink: { line in lines.withLock { $0.append(line) } }), lines)
    }

    private func decode(_ json: String, _ diagnostics: SettingsDiagnostics) throws -> Settings {
        let decoder = AutoNoteJSON.decoder()
        decoder.userInfo[SettingsDiagnostics.userInfoKey] = diagnostics
        return try decoder.decode(Settings.self, from: Data(json.utf8))
    }

    @Test func anUnknownEngineKindIsReportedOncePerValue() {
        let (diagnostics, lines) = recorder()
        // `system` is a track's name, not an engine.
        for _ in 0..<3 {
            #expect(EngineChoice.fromSettings(kind: "system", model: "small", role: .live, machine: .appleSilicon,
                                              diagnostics: diagnostics) == nil)
        }
        #expect(lines.withLock { $0 } == [
            #"settings: ignored live_engine "system" (known: dictation, speech, whisper); using this Mac's default engine"#,
        ])
        #expect(EngineChoice.fromSettings(kind: "system", model: nil, role: .batch, machine: .intel, diagnostics: diagnostics) == nil)
        #expect(EngineChoice.fromSettings(kind: "sf", model: nil, role: .live, machine: .intel, diagnostics: diagnostics) == nil)
        #expect(lines.withLock { $0 }.dropFirst() == [
            #"settings: ignored final_engine "system" (known: dictation, speech, whisper); using this Mac's default engine"#,
            #"settings: ignored live_engine "sf" (known: dictation, speech, whisper); using this Mac's default engine"#,
        ])
    }

    @Test func knownAndMissingEngineKindsReportNothing() {
        let (diagnostics, lines) = recorder()
        #expect(EngineChoice.fromSettings(kind: nil, model: nil, role: .live, machine: .intel, diagnostics: diagnostics) == nil)
        #expect(EngineChoice.fromSettings(kind: "speech", model: nil, role: .live, machine: .intel, diagnostics: diagnostics) == .speech)
        #expect(EngineChoice.fromSettings(kind: "whisper", model: "base", role: .batch, machine: .intel, diagnostics: diagnostics)
                == .whisper("base"))
        #expect(lines.withLock { $0 }.isEmpty)
    }

    @Test func unknownTranslationValuesFallBackAndAreReported() throws {
        let (diagnostics, lines) = recorder()
        let s = try decode(#"{"translation_mode":"always","translation_target":7,"countdown_seconds":3}"#, diagnostics)
        #expect(s.translationMode == .off)
        #expect(s.translationTarget == .auto)
        #expect(s.countdownSeconds == 3)      // the rest of the file is still read
        #expect(lines.withLock { $0 } == [
            #"settings: ignored translation_mode "always" (known: off, after_recording, during_recording); using off"#,
            #"settings: ignored translation_target "(not a string)" (known: auto, ja, en); using auto"#,
        ])
        // Known values, null and a missing key report nothing.
        let ok = try decode(#"{"translation_mode":"after_recording","translation_target":null}"#, diagnostics)
        #expect(ok.translationMode == .afterRecording)
        #expect(ok.translationTarget == .auto)
        #expect(lines.withLock { $0 }.count == 2)
    }

    @Test func droppedClaudeEnvNamesAreCountedNotNamed() throws {
        let (diagnostics, lines) = recorder()
        let s = try decode(#"{"claude_env":{"GOOD_NAME":"made-up-value","1BAD":"x","also bad":"y"}}"#, diagnostics)
        #expect(s.claudeEnv == ["GOOD_NAME": "made-up-value"])
        #expect(lines.withLock { $0 } == [
            "settings: ignored 2 claude_env name(s) (a name is [A-Za-z_][A-Za-z0-9_]*); those variables are not set",
        ])
        // Neither the names nor the values reach the log.
        for word in ["1BAD", "also bad", "GOOD_NAME", "made-up-value"] {
            #expect(lines.withLock { $0 }.allSatisfy { !$0.contains(word) })
        }
    }

    @Test func aLongOrMultiLineValueIsCutToOneLine() {
        let (diagnostics, lines) = recorder()
        let long = "line one\nline two " + String(repeating: "x", count: 200)
        _ = EngineChoice.fromSettings(kind: long, model: nil, role: .live, machine: .intel, diagnostics: diagnostics)
        let line = lines.withLock { $0 }.first ?? ""
        #expect(line.hasPrefix(#"settings: ignored live_engine "line one line two xxx"#))
        #expect(!line.contains("\n"))
        #expect(line.contains(String(repeating: "x", count: SettingsDiagnostics.valueLimit - "line one line two ".count) + "…\""))
        #expect(!line.contains(String(repeating: "x", count: SettingsDiagnostics.valueLimit)))
    }

    @Test func aSettingsFileSetAsideSaysWhyAndWhere() async throws {
        let (diagnostics, lines) = recorder()
        let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
        try Data(#"{"default_language":"fr","claude_env":{"NAME":"made-up-value"}}"#.utf8).write(to: p.settingsFile)
        let store = SettingsStore(paths: p, timeZone: Samples.tokyo, diagnostics: diagnostics)
        #expect(try await store.load() == Settings())
        let aside = try #require(await store.lastSetAside)
        #expect(lines.withLock { $0 } == [
            "settings: settings.json could not be read (invalid value at default_language); moved to \(aside.lastPathComponent), using the defaults",
        ])
        #expect(lines.withLock { $0 }.allSatisfy { !$0.contains("made-up-value") && !$0.contains("fr") })
    }

    /// Each in its own folder: the set-aside name has whole seconds, so two in one folder could collide.
    @Test(arguments: [("{not json", "not valid JSON"),
                      (#"{"countdown_seconds":"three"}"#, "wrong type at countdown_seconds"),
                      (#"{"shortcuts":{"bookmark":5}}"#, "wrong type at shortcuts.bookmark"),
                      (#"{"claude_env":{"NAME":5}}"#, "wrong type at claude_env")])
    func aSettingsFileSetAsideNamesWhereItFailed(json: String, reason: String) async throws {
        let (diagnostics, lines) = recorder()
        let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
        try Data(json.utf8).write(to: p.settingsFile)
        #expect(try await SettingsStore(paths: p, diagnostics: diagnostics).load() == Settings())
        let line = try #require(lines.withLock { $0 }.first)
        #expect(line.hasPrefix("settings: settings.json could not be read (\(reason)); moved to settings.json.corrupt-"))
        #expect(!line.contains("NAME"))
    }

    @Test func theStorePassesItsDiagnosticsToTheDecoder() async throws {
        let (diagnostics, lines) = recorder()
        let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
        try Data(#"{"translation_mode":"always","live_engine":"system"}"#.utf8).write(to: p.settingsFile)
        let store = SettingsStore(paths: p, diagnostics: diagnostics)
        for _ in 0..<3 { #expect(try await store.load().liveEngine == "system") }   // the raw value stays in the file
        #expect(lines.withLock { $0 } == [
            #"settings: ignored translation_mode "always" (known: off, after_recording, during_recording); using off"#,
        ])
    }
}
