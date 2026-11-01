import Foundation

/// A whisper model that is too heavy for this Mac. The wording lives in `FitWarningPresentation`.
public enum FitWarning: Hashable, Sendable {
    /// Final transcription on Intel (no Metal) with a large model: about 1.0–1.3× the recording, CPU busy throughout.
    case finalTooSlow(model: String)
    /// Final transcription with a model that wants more memory than this Mac has (swap grows).
    case finalLowMemory(model: String)
    /// Live whisper on Intel (no Metal) with a model larger than small: it cannot keep up with real time.
    case liveTooSlow(model: String)
}

/// Whether the chosen whisper models suit the machine (docs/guide/getting-started.md §9). Pure: callers pass the
/// profile and the engines that will actually run (the resolved choice, or the one picked on the settings screen).
public enum WhisperModelFit {
    /// The large models: too slow on Intel for final transcription, and for live transcription.
    public static let largeModels: Set<String> = ["large-v3-turbo", "large-v3-turbo-q5_0"]

    /// The physical memory below which a model is flagged. large-v3-turbo needs about 2 GB while it runs and is
    /// recommended for 16 GB or more (the guide's table: on 8 GB swap grows when other apps are open). The other
    /// models fit 8 GB, the smallest Mac macOS 26 runs on, so they have no threshold.
    public static func minimumMemory(for model: String) -> UInt64? {
        model == "large-v3-turbo" ? 16 << 30 : nil
    }

    /// Final warnings first (speed, then memory), then live. `nil` or a non-whisper engine adds nothing.
    public static func warnings(profile: MachineProfile, final: EngineChoice?, live: EngineChoice?) -> [FitWarning] {
        var out: [FitWarning] = []
        if let model = whisperModel(final) {
            if profile.kind == .intel, largeModels.contains(model) { out.append(.finalTooSlow(model: model)) }
            if let minimum = minimumMemory(for: model), profile.physicalMemory < minimum {
                out.append(.finalLowMemory(model: model))
            }
        }
        if let model = whisperModel(live), profile.kind == .intel, largeModels.contains(model) {
            out.append(.liveTooSlow(model: model))
        }
        return out
    }

    private static func whisperModel(_ c: EngineChoice?) -> String? {
        guard let c, c.kind == .whisper, let model = c.model, !model.isEmpty else { return nil }
        return model
    }
}
