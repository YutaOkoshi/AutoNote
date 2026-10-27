import Foundation
import Testing
import AutoNoteCore

@Suite struct SettingsDraftsTests {
    @Test func dictionaryDraftTrimsAndDropsEmpty() throws {
        // terms ["AutoNote", "  所沢 ", ""] → toFile().terms == ["AutoNote", "所沢"]
        var d = DictionaryDraft(.default)
        d.terms = ["AutoNote", "  所沢 ", ""]
        d.fillers = [" えー ", "", "um"]
        let f = try d.toFile()
        #expect(f.terms == ["AutoNote", "所沢"])
        #expect(f.fillers == ["えー", "um"])
    }

    @Test func dictionaryDraftRejectsHalfEmptyReplacement() {
        // [オートノート => AutoNote, クーバ => " "] → throws .invalid("置換の左右どちらかが空です（2 行目）")
        var d = DictionaryDraft(.default)
        d.replacements = [Replacement(from: "オートノート", to: "AutoNote"), Replacement(from: "クーバ", to: " ")]
        #expect(throws: AppCommandError.invalid("置換の左右どちらかが空です（2 行目）")) { try d.toFile() }
    }

    @Test func dictionaryDraftRoundTripsThroughRender() throws {
        let file = DictionaryFile(terms: ["AutoNote"], replacements: [Replacement(from: "オートノート", to: "AutoNote")],
                                  fillers: ["えー"])
        let parsed = DictionaryFile.parse(try DictionaryDraft(file).toFile().render())
        #expect(parsed.dictionary == file && parsed.issues.isEmpty)
    }

    @Test func automationDraftValidation() {
        // 名前 "" → ["名前を入れてください"]、command " " → ["コマンドを入れてください"]、
        // timeout 0 → ["タイムアウトは 1〜86400 秒にしてください"]、既存と同名 → ["同じ名前の Automation があります"]
        let ok = AutomationDefinition(name: "a", on: .minutesGenerated, command: "true", timeoutSec: 60)
        func with(_ change: (inout AutomationDefinition) -> Void) -> AutomationDefinition {
            var d = ok
            change(&d)
            return d
        }
        #expect(AutomationDraft.validate(ok, existing: []) == [])
        #expect(AutomationDraft.validate(with { $0.name = "" }, existing: []) == ["名前を入れてください"])
        #expect(AutomationDraft.validate(with { $0.command = " " }, existing: []) == ["コマンドを入れてください"])
        #expect(AutomationDraft.validate(with { $0.timeoutSec = 0 }, existing: []) == ["タイムアウトは 1〜86400 秒にしてください"])
        #expect(AutomationDraft.validate(with { $0.timeoutSec = 86_401 }, existing: []) == ["タイムアウトは 1〜86400 秒にしてください"])
        #expect(AutomationDraft.validate(with { $0.timeoutSec = 86_400 }, existing: []) == [])
        let other = AutomationDefinition(name: "a", on: .transcriptOnly, command: "echo")
        #expect(AutomationDraft.validate(ok, existing: [other]) == ["同じ名前の Automation があります"])
    }

    /// X23: the settings sheet and `AutomationsFile.load` share one validator, so they give the same copy.
    @Test func fileLoadAndDraftShareTheDuplicateMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("automations.json")
        let def = AutomationDefinition(name: "dup", on: .minutesGenerated, command: "true")
        try AutomationsFile(url: url).save([def, def])
        let loaded = AutomationsFile(url: url).load()
        let fromFile = try #require(loaded.items.last?.problem)
        #expect(AutomationDraft.validate(def, existing: [def]) == [fromFile])
        #expect(fromFile == "同じ名前の Automation があります")
    }

    @Test func normalizerUsesAutoRecordConfig() {
        // countdownSeconds 45 → 30、-1 → 0、disconnectGraceSeconds 0 → 5、999 → 300、audioRetentionDays -3 → 0
        var s = AutoNoteCore.Settings(); s.countdownSeconds = 45; s.disconnectGraceSeconds = 0
        let n = SettingsNormalizer.normalized(s)
        #expect(n.countdownSeconds == AutoRecordCoordinator.config(from: s).countdownSeconds && n.disconnectGraceSeconds == 5)
        #expect(n.countdownSeconds == 30)

        var t = AutoNoteCore.Settings(); t.countdownSeconds = -1; t.disconnectGraceSeconds = 999; t.audioRetentionDays = -3
        let m = SettingsNormalizer.normalized(t)
        #expect(m.countdownSeconds == 0 && m.disconnectGraceSeconds == 300)
        #expect(m.audioRetentionDays == 0)

        var u = AutoNoteCore.Settings(); u.audioRetentionDays = 0
        #expect(SettingsNormalizer.normalized(u).audioRetentionDays == 0)
        u.audioRetentionDays = 45
        #expect(SettingsNormalizer.normalized(u) == u)
    }
}
