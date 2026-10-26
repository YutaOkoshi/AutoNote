import AutoNoteCore
import Foundation

/// `autonote dev engines [--data <dir>]` — prints one JSON object: the machine, what the Apple engines report,
/// the live / batch engine lists, the machine defaults and the choice resolved with the settings in `--data`
/// (default `AppPaths.resolve()`). The engine lists and `resolved` use the settings' default language.
enum DevEngines {
    static let usage = "usage: autonote dev engines [--data <dir>]"

    private struct SpeechTranscriberInfo: Encodable {
        var isAvailable: Bool
        var supportedLocales: Int
    }

    private struct DictationInfo: Encodable {
        var supportedLocales: Int
    }

    private struct Defaults: Encodable {
        var live: EngineChoice
        var batch: EngineChoice
        var whisperLiveModel: String
    }

    private struct Resolved: Encodable {
        var live: EngineChoice?
        var batch: EngineChoice?

        func encode(to encoder: any Encoder) throws {   // keep `null` visible when nothing is usable
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(live, forKey: .live)
            try c.encode(batch, forKey: .batch)
        }

        private enum CodingKeys: String, CodingKey { case live, batch }
    }

    private struct Output: Encodable {
        var machine: MachineKind
        var language: Language
        var speechTranscriber: SpeechTranscriberInfo
        var dictation: DictationInfo
        var live: [EngineEntry]
        var batch: [EngineEntry]
        var defaults: Defaults
        var resolved: Resolved
    }

    static func run(_ args: [String]) async -> Int32 {
        guard let paths = DevCommands.dataPaths(args) else { return DevCommands.usageError(usage) }
        do {
            let settings = try await SettingsStore(paths: paths).load()
            let machine = MachineKind.current()
            let speech = AppleSpeechCapabilities()
            let models = ModelManager(directory: paths.modelsDirectory)
            let catalog = EngineCatalog(machine: machine, speech: speech,
                                        installedModels: { await models.installed().map(\.name) })
            let language = settings.defaultLanguage
            let d = EngineCatalog.defaults(for: machine)
            let liveOverride = EngineChoice.fromSettings(kind: settings.liveEngine, model: settings.liveModel, role: .live, machine: machine)
            let batchOverride = EngineChoice.fromSettings(kind: settings.finalEngine, model: settings.finalModel, role: .batch, machine: machine)
            let output = Output(
                machine: machine, language: language,
                speechTranscriber: SpeechTranscriberInfo(isAvailable: await speech.speechTranscriberIsAvailable(),
                                                         supportedLocales: await speech.speechTranscriberLocales().count),
                dictation: DictationInfo(supportedLocales: await speech.dictationLocales().count),
                live: await catalog.entries(role: .live, language: language),
                batch: await catalog.entries(role: .batch, language: language),
                defaults: Defaults(live: d.live, batch: d.batch, whisperLiveModel: d.whisperLiveModel),
                resolved: Resolved(live: await catalog.resolve(role: .live, language: language, override: liveOverride),
                                   batch: await catalog.resolve(role: .batch, language: language, override: batchOverride)))
            print(String(decoding: try AutoNoteJSON.encoder().encode(output), as: UTF8.self))
            return 0
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }
}
