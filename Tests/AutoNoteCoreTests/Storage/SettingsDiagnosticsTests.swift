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

    private final class Clock: Sendable {
        private let time = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    /// The app stays up for days: a value that is still ignored is written again once the interval has passed, so
    /// `log show --last 1h` finds it after the next recording starts.
    @Test func theSameLineComesBackAfterTheInterval() {
        let lines = LockedBox<[String]>([])
        let clock = Clock()
        let diagnostics = SettingsDiagnostics(sink: { line in lines.withLock { $0.append(line) } }, now: { clock.now })
        diagnostics.report("a"); diagnostics.report("a"); diagnostics.report("b")
        #expect(lines.withLock { $0 } == ["a", "b"])
        clock.advance(SettingsDiagnostics.repeatInterval - 1)
        diagnostics.report("a")
        #expect(lines.withLock { $0 } == ["a", "b"])
        clock.advance(1)
        diagnostics.report("a"); diagnostics.report("a")
        #expect(lines.withLock { $0 } == ["a", "b", "a"])
        // A clock set back does not silence a line for good.
        clock.advance(-86_400)
        diagnostics.report("a")
        #expect(lines.withLock { $0 } == ["a", "b", "a", "a"])
        #expect(SettingsDiagnostics.repeatInterval <= 30 * 60)   // well inside the hour the guide's command reads
    }

    private func catalog(installed: [String] = [], speech: Bool = true) -> EngineCatalog {
        EngineCatalog(machine: .appleSilicon,
                      speech: FakeSpeechCapabilities(speechAvailable: speech, speechLocales: speech ? ["ja-JP"] : [],
                                                     dictationLocales: ["ja-JP"]),
                      installedModels: { installed })
    }

    /// A known engine that cannot run falls back too: only whisper transcribes a finished recording, a model may not
    /// be downloaded, or not be a whisper model at all. The line names the reason and what runs instead.
    @Test func anEngineThatCannotRunIsReportedWithWhatRunsInstead() async {
        let (diagnostics, lines) = recorder()
        let c = catalog(installed: ["small"])
        let apple = EngineChoice.fromSettings(kind: "speech", model: nil, role: .batch, machine: .appleSilicon, diagnostics: diagnostics)
        #expect(apple == .speech)       // returned as written: the settings screen still shows the file's value
        #expect(await c.resolve(role: .batch, language: .ja, override: apple, diagnostics: diagnostics) == .whisper("small"))
        #expect(await c.resolve(role: .batch, language: .ja, override: .whisper("large-v3-turbo"), diagnostics: diagnostics) == .whisper("small"))
        #expect(await c.resolve(role: .live, language: .ja, override: .whisper("larg-v3"), diagnostics: diagnostics) == .speech)
        #expect(lines.withLock { $0 } == [
            #"settings: ignored final_engine "speech" (only whisper can be the final engine); using whisper.cpp small"#,
            #"settings: ignored final_engine "whisper" with model "large-v3-turbo" (model large-v3-turbo is not downloaded); using whisper.cpp small"#,
            #"settings: ignored live_engine "whisper" with model "larg-v3" (not a whisper model AutoNote knows); using Apple SpeechTranscriber"#,
        ])
        // Nothing can run at all.
        let none = catalog(installed: [])
        #expect(await none.resolve(role: .batch, language: .ja, override: .whisper("base"), diagnostics: diagnostics) == nil)
        #expect(lines.withLock { $0 }.last
                == #"settings: ignored final_engine "whisper" with model "base" (model base is not downloaded); using no engine (none can run)"#)
    }

    @Test func anEngineThatRunsAndNoOverrideReportNothing() async {
        let (diagnostics, lines) = recorder()
        let c = catalog(installed: ["small"])
        #expect(await c.resolve(role: .batch, language: .ja, override: .whisper("small"), diagnostics: diagnostics) == .whisper("small"))
        #expect(await c.resolve(role: .live, language: .ja, override: .dictation, diagnostics: diagnostics) == .dictation)
        #expect(await c.resolve(role: .live, language: .ja, override: nil, diagnostics: diagnostics) == .speech)
        #expect(await c.resolve(role: .batch, language: .ja, override: nil, diagnostics: diagnostics) == .whisper("small"))
        #expect(lines.withLock { $0 }.isEmpty)
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
            #"settings: ignored final_engine "system" (known: whisper); using this Mac's default engine"#,
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
