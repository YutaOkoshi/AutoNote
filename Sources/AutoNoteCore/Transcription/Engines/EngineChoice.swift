import Foundation

public enum EngineKind: String, Codable, Sendable, CaseIterable { case dictation, speech, whisper }

public enum EngineRole: String, Codable, Sendable { case live, batch }

public struct EngineChoice: Codable, Hashable, Sendable {
    public var kind: EngineKind
    public var model: String?

    public init(kind: EngineKind, model: String? = nil) {
        self.kind = kind
        self.model = model
    }

    public static func whisper(_ m: String) -> EngineChoice { EngineChoice(kind: .whisper, model: m) }
    public static let dictation = EngineChoice(kind: .dictation)
    public static let speech = EngineChoice(kind: .speech)

    /// Value written to the frontmatter `transcript_engine`.
    public var displayName: String {
        switch kind {
        case .dictation: return "Apple DictationTranscriber"
        case .speech: return "Apple SpeechTranscriber"
        case .whisper: return "whisper.cpp \(model ?? "")"
        }
    }

    /// Parses `Settings.liveEngine/liveModel` (live) or `finalEngine/finalModel` (batch).
    /// Returns nil for a missing or unknown kind. A whisper choice without a model gets the machine's default for the role.
    public static func fromSettings(kind: String?, model: String?, role: EngineRole, machine: MachineKind) -> EngineChoice? {
        guard let kind, let parsed = EngineKind(rawValue: kind) else { return nil }
        switch parsed {
        case .dictation: return .dictation
        case .speech: return .speech
        case .whisper:
            let d = EngineCatalog.defaults(for: machine)
            let fallback = role == .live ? d.whisperLiveModel : (d.batch.model ?? d.whisperLiveModel)
            return .whisper(model ?? fallback)
        }
    }
}

public struct EngineEntry: Codable, Equatable, Sendable {
    public var choice: EngineChoice
    public var available: Bool
    public var reason: String?

    public init(choice: EngineChoice, available: Bool, reason: String? = nil) {
        self.choice = choice
        self.available = available
        self.reason = reason
    }
}
