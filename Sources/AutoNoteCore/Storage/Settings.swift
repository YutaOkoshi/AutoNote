import Foundation

public enum SummarizerKind: String, Codable, Sendable {
    case claudeCode = "claude_code"
}

public struct Shortcuts: Codable, Equatable, Sendable {
    public var bookmark: String
    public var toggleRecording: String
    public var togglePause: String

    public init(bookmark: String = "ctrl+option+b", toggleRecording: String = "ctrl+option+r", togglePause: String = "ctrl+option+p") {
        self.bookmark = bookmark; self.toggleRecording = toggleRecording; self.togglePause = togglePause
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Shortcuts()
        bookmark = try c.decodeIfPresent(String.self, forKey: .bookmark) ?? d.bookmark
        toggleRecording = try c.decodeIfPresent(String.self, forKey: .toggleRecording) ?? d.toggleRecording
        togglePause = try c.decodeIfPresent(String.self, forKey: .togglePause) ?? d.togglePause
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var outputFolder: String? = nil
    public var claudePath: String? = nil
    public var claudeModel: String? = nil
    public var summarizerKind: SummarizerKind = .claudeCode
    public var launchAtLogin: Bool = true
    public var defaultLanguage: Language = .ja
    public var liveEngine: String? = nil
    public var liveModel: String? = nil
    public var finalEngine: String? = nil
    public var finalModel: String? = nil
    public var voiceProcessing: Bool = false
    public var fillerRemoval: Bool = true
    public var countdownSeconds: Int = 5 { didSet { countdownSeconds = Self.clamp(countdownSeconds, 0, 30) } }
    public var disconnectGraceSeconds: Int = 30 { didSet { disconnectGraceSeconds = Self.clamp(disconnectGraceSeconds, 5, 300) } }
    public var startOnModelMatch: Bool = false
    public var audioRetentionDays: Int = 30
    public var shortcuts: Shortcuts = Shortcuts()
    public var consentNoticeShown: Bool = false

    public init() {}

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel)
        summarizerKind = try c.decodeIfPresent(SummarizerKind.self, forKey: .summarizerKind) ?? summarizerKind
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        defaultLanguage = try c.decodeIfPresent(Language.self, forKey: .defaultLanguage) ?? defaultLanguage
        liveEngine = try c.decodeIfPresent(String.self, forKey: .liveEngine)
        liveModel = try c.decodeIfPresent(String.self, forKey: .liveModel)
        finalEngine = try c.decodeIfPresent(String.self, forKey: .finalEngine)
        finalModel = try c.decodeIfPresent(String.self, forKey: .finalModel)
        voiceProcessing = try c.decodeIfPresent(Bool.self, forKey: .voiceProcessing) ?? voiceProcessing
        fillerRemoval = try c.decodeIfPresent(Bool.self, forKey: .fillerRemoval) ?? fillerRemoval
        countdownSeconds = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? countdownSeconds, 0, 30)
        disconnectGraceSeconds = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .disconnectGraceSeconds) ?? disconnectGraceSeconds, 5, 300)
        startOnModelMatch = try c.decodeIfPresent(Bool.self, forKey: .startOnModelMatch) ?? startOnModelMatch
        audioRetentionDays = try c.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? audioRetentionDays
        shortcuts = try c.decodeIfPresent(Shortcuts.self, forKey: .shortcuts) ?? shortcuts
        consentNoticeShown = try c.decodeIfPresent(Bool.self, forKey: .consentNoticeShown) ?? consentNoticeShown
    }
}
