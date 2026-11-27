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

    /// The engine that runs as `role`: `override` (the settings' choice) when it can run, else the machine's default
    /// for the role, else the first usable candidate; nil when nothing can run. An `override` that cannot run (an
    /// Apple engine as the final engine, a model that is not downloaded or not a whisper model, an engine without
    /// this language) is reported to `diagnostics` with the reason and what runs instead.
    public func resolve(role: EngineRole, language: Language, override: EngineChoice?,
                        diagnostics: SettingsDiagnostics = .shared) async -> EngineChoice? {
        let list = await entries(role: role, language: language)
        func usable(_ c: EngineChoice) -> Bool { list.first { $0.choice == c }?.available == true }

        if let override, usable(override) { return override }
        let d = Self.defaults(for: machine)
        let roleDefault = role == .live ? d.live : d.batch
        var candidates = [roleDefault]
        if role == .live { candidates += [.dictation, .speech, .whisper(d.whisperLiveModel)] }
        candidates += Self.batchModelPreference.map { .whisper($0) }
        let resolved = candidates.first(where: usable)
        if let override {
            diagnostics.report(SettingsDiagnostics.unusableEngine(
                key: EngineChoice.settingsKey(role), kind: override.kind.rawValue, model: override.model,
                why: Self.whyUnusable(override, role: role, entry: list.first { $0.choice == override }),
                using: resolved?.displayName ?? "no engine (none can run)"))
        }
        return resolved
    }

    /// Why `choice` cannot run as `role`: its entry's reason, or why it has no entry.
    private static func whyUnusable(_ choice: EngineChoice, role: EngineRole, entry: EngineEntry?) -> String {
        if let reason = entry?.reason { return reason }
        if !EngineChoice.kinds(for: role).contains(choice.kind) {
            return "only \(EngineChoice.kinds(for: role).map(\.rawValue).joined(separator: ", ")) can be the \(role == .live ? "live" : "final") engine"
        }
        return choice.kind == .whisper ? "not a whisper model AutoNote knows" : "not available"
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
