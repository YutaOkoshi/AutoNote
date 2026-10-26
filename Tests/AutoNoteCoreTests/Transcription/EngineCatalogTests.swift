import Testing
import Foundation
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct EngineCatalogTests {
    private func catalog(_ machine: MachineKind, speechAvailable: Bool = false, speech: [String] = [],
                         dictation: [String] = ["ja-JP", "en-US"], installed: [String] = []) -> EngineCatalog {
        EngineCatalog(machine: machine,
                      speech: FakeSpeechCapabilities(speechAvailable: speechAvailable, speechLocales: speech, dictationLocales: dictation),
                      installedModels: { installed })
    }

    @Test func intelDefaults() {
        let d = EngineCatalog.defaults(for: .intel)
        #expect(d.live == .dictation); #expect(d.batch == .whisper("large-v3-turbo")); #expect(d.whisperLiveModel == "small")
    }

    @Test func appleSiliconProvisionalDefaults() {
        let d = EngineCatalog.defaults(for: .appleSilicon)
        #expect(d.live == .speech); #expect(d.batch == .whisper("large-v3-turbo")); #expect(d.whisperLiveModel == "small")
    }

    @Test(arguments: [(true, [String]()), (false, ["ja-JP"])])
    func speechTranscriberNeedsBothFlags(isAvailable: Bool, locales: [String]) async {
        let c = EngineCatalog(machine: .appleSilicon,
                              speech: FakeSpeechCapabilities(speechAvailable: isAvailable, speechLocales: locales, dictationLocales: ["ja-JP"]),
                              installedModels: { [] })
        #expect(await c.entries(role: .live, language: .ja).first { $0.choice == .speech }?.available == false)
        #expect(await c.resolve(role: .live, language: .ja, override: nil) == .dictation)
    }

    @Test func speechAvailableWhenBothFlagsHold() async {
        let c = catalog(.appleSilicon, speechAvailable: true, speech: ["ja-JP"])
        #expect(await c.entries(role: .live, language: .ja).first { $0.choice == .speech }?.available == true)
        #expect(await c.resolve(role: .live, language: .ja, override: nil) == .speech)
    }

    @Test func dictationJudgedByLocales() async {
        let c = catalog(.intel, dictation: ["en-US"])
        let e = await c.entries(role: .live, language: .ja).first { $0.choice == .dictation }
        #expect(e?.available == false)
        #expect(e?.reason?.contains("ja-JP") == true)
    }

    @Test func appleIdentifiersWithUnderscoreMatch() async {
        let c = catalog(.intel, dictation: ["ja_JP"])
        #expect(await c.entries(role: .live, language: .ja).first { $0.choice == .dictation }?.available == true)
    }

    @Test func autoLanguageUsesJapaneseLocale() {
        #expect(LocaleMapping.locale(for: .auto).identifier(.bcp47) == "ja-JP")
        #expect(LocaleMapping.locale(for: .ja).identifier(.bcp47) == "ja-JP")
        #expect(LocaleMapping.locale(for: .en).identifier(.bcp47) == "en-US")
    }

    @Test func whisperNeedsModel() async {
        #expect(await catalog(.intel, installed: []).resolve(role: .batch, language: .ja, override: nil) == nil)
        #expect(await catalog(.intel, installed: ["small"]).resolve(role: .batch, language: .ja, override: nil) == .whisper("small"))
    }

    @Test func batchEntriesAreWhisperOnly() async {
        let entries = await catalog(.intel, installed: ["small"]).entries(role: .batch, language: .ja)
        #expect(entries.allSatisfy { $0.choice.kind == .whisper })
        #expect(entries.first { $0.choice == .whisper("small") }?.available == true)
        #expect(entries.first { $0.choice == .whisper("large-v3-turbo") }?.reason == "model large-v3-turbo is not downloaded")
    }

    @Test func liveResolveFallsBackToWhisperDefaultThenInstalled() async {
        let c = catalog(.intel, dictation: [], installed: ["base", "small"])
        #expect(await c.resolve(role: .live, language: .ja, override: nil) == .whisper("small"))
        let c2 = catalog(.intel, dictation: [], installed: ["base"])
        #expect(await c2.resolve(role: .live, language: .ja, override: nil) == .whisper("base"))
    }

    @Test func overrideWinsWhenAvailable() async {
        let c = catalog(.intel, installed: ["small"])
        #expect(await c.resolve(role: .live, language: .ja, override: .whisper("small")) == .whisper("small"))
    }

    @Test func overrideFallsBackWhenUnavailable() async {
        let c = catalog(.intel)
        #expect(await c.resolve(role: .live, language: .ja, override: .speech) == .dictation)
    }

    @Test func settingsParsing() {
        #expect(EngineChoice.fromSettings(kind: "whisper", model: nil, role: .batch, machine: .intel) == .whisper("large-v3-turbo"))
        #expect(EngineChoice.fromSettings(kind: "whisper", model: nil, role: .live, machine: .intel) == .whisper("small"))
        #expect(EngineChoice.fromSettings(kind: "whisper", model: "base", role: .live, machine: .intel) == .whisper("base"))
        #expect(EngineChoice.fromSettings(kind: "dictation", model: nil, role: .live, machine: .intel) == .dictation)
        #expect(EngineChoice.fromSettings(kind: "sf", model: nil, role: .live, machine: .intel) == nil)
        #expect(EngineChoice.fromSettings(kind: nil, model: nil, role: .live, machine: .intel) == nil)
    }

    @Test func displayNames() {
        #expect(EngineChoice.whisper("large-v3-turbo").displayName == "whisper.cpp large-v3-turbo")
        #expect(EngineChoice.dictation.displayName == "Apple DictationTranscriber")
        #expect(EngineChoice.speech.displayName == "Apple SpeechTranscriber")
    }
}
