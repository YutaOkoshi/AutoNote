import Foundation

public struct EngineCatalog: Sendable {
    public let machine: MachineKind
    private let speech: any SpeechCapabilityProbing
    private let installedModels: @Sendable () async -> [String]

    public init(machine: MachineKind, speech: any SpeechCapabilityProbing,
                installedModels: @Sendable @escaping () async -> [String]) {
        self.machine = machine
        self.speech = speech
        self.installedModels = installedModels
    }

    public static func defaults(for machine: MachineKind) -> (live: EngineChoice, batch: EngineChoice, whisperLiveModel: String) {
        switch machine {
        case .intel:
            return (.dictation, .whisper("large-v3-turbo"), "small")
        case .appleSilicon:
            // Provisional: revisit after the Apple Silicon measurements.
            return (.speech, .whisper("large-v3-turbo"), "small")
        }
    }

    /// Preference order when picking among downloaded models for a batch run.
    private static let batchModelPreference = ["large-v3-turbo", "large-v3-turbo-q5_0", "small", "base"]

    public func entries(role: EngineRole, language: Language) async -> [EngineEntry] {
        let installed = await installedModels()
        var out: [EngineEntry] = []
        if role == .live {
            out.append(await dictationEntry(language))
            out.append(await speechEntry(language))
        }
        for model in WhisperModelCatalog.all.map(\.name) {
            let ok = installed.contains(model)
            out.append(EngineEntry(choice: .whisper(model), available: ok,
                                   reason: ok ? nil : "model \(model) is not downloaded"))
        }
        return out
    }

    public func resolve(role: EngineRole, language: Language, override: EngineChoice?) async -> EngineChoice? {
        let list = await entries(role: role, language: language)
        func usable(_ c: EngineChoice) -> Bool { list.first { $0.choice == c }?.available == true }

        let d = Self.defaults(for: machine)
        if let override, usable(override) { return override }
        let roleDefault = role == .live ? d.live : d.batch
        if usable(roleDefault) { return roleDefault }

        var candidates: [EngineChoice] = []
        if role == .live { candidates += [.dictation, .speech, .whisper(d.whisperLiveModel)] }
        candidates += Self.batchModelPreference.map { .whisper($0) }
        return candidates.first(where: usable)
    }

    private func dictationEntry(_ language: Language) async -> EngineEntry {
        let target = LocaleMapping.locale(for: language)
        let ok = LocaleMapping.contains(await speech.dictationLocales(), target)
        return EngineEntry(choice: .dictation, available: ok,
                           reason: ok ? nil : "\(target.identifier(.bcp47)) is not in DictationTranscriber.supportedLocales")
    }

    private func speechEntry(_ language: Language) async -> EngineEntry {
        let target = LocaleMapping.locale(for: language)
        guard await speech.speechTranscriberIsAvailable() else {
            return EngineEntry(choice: .speech, available: false, reason: "SpeechTranscriber.isAvailable is false")
        }
        let locales = await speech.speechTranscriberLocales()
        guard !locales.isEmpty else {
            return EngineEntry(choice: .speech, available: false, reason: "SpeechTranscriber.supportedLocales is empty")
        }
        let ok = LocaleMapping.contains(locales, target)
        return EngineEntry(choice: .speech, available: ok,
                           reason: ok ? nil : "\(target.identifier(.bcp47)) is not in SpeechTranscriber.supportedLocales")
    }
}
