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
    /// Threads for final (batch) whisper; nil = automatic (`MachineProfile.automaticBatchThreads`). Kept inside
    /// `MachineProfile.batchThreadRange`. JSON `final_threads`.
    public var finalThreads: Int? = nil { didSet { finalThreads = finalThreads.map(Self.clampThreads) } }
    public var voiceProcessing: Bool = false
    public var fillerRemoval: Bool = true
    public var countdownSeconds: Int = 5 { didSet { countdownSeconds = Self.clamp(countdownSeconds, 0, 30) } }
    public var disconnectGraceSeconds: Int = 30 { didSet { disconnectGraceSeconds = Self.clamp(disconnectGraceSeconds, 5, 300) } }
    public var startOnModelMatch: Bool = false
    public var audioRetentionDays: Int = 30
    public var shortcuts: Shortcuts = Shortcuts()
    /// True once the first launch has run (output folder default, main window opened). JSON `first_run_completed`.
    public var firstRunCompleted: Bool = false
    /// Live summary during recording (off by default: it sends confirmed live text to Claude Code). JSON `live_summary_enabled`.
    public var liveSummaryEnabled: Bool = false
    /// Seconds between live summary updates, kept inside `liveSummaryIntervalRange`. JSON `live_summary_interval_seconds`.
    public var liveSummaryIntervalSeconds: Int = 20 {
        didSet { liveSummaryIntervalSeconds = Self.clamp(liveSummaryIntervalSeconds, Self.liveSummaryIntervalRange.lowerBound, Self.liveSummaryIntervalRange.upperBound) }
    }
    /// Model for the live summary; never empty. JSON `live_summary_model`.
    public var liveSummaryModel: String = Settings.defaultLiveSummaryModel

    public static let liveSummaryIntervalRange: ClosedRange<Int> = 10...120
    public static let defaultLiveSummaryModel = "haiku"

    public init() {}

    /// The `settings.json` key names whose values differ between `old` and `new`, sorted; a nested object names the
    /// inner key (`shortcuts.toggle_recording`). For the log of a settings save, which never shows the values.
    public static func changedKeys(from old: Settings, to new: Settings) -> [String] {
        func object(_ s: Settings) -> [String: Any] {
            guard let data = try? AutoNoteJSON.encoder().encode(s),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
        func diff(_ a: [String: Any], _ b: [String: Any], prefix: String) -> [String] {
            Set(a.keys).union(b.keys).flatMap { key -> [String] in
                let name = prefix + key
                switch (a[key], b[key]) {
                case (let x as [String: Any], let y as [String: Any]): return diff(x, y, prefix: name + ".")
                case (let x as NSObject, let y as NSObject): return x.isEqual(y) ? [] : [name]
                case (nil, nil): return []
                default: return [name]
                }
            }
        }
        return diff(object(old), object(new), prefix: "").sorted()
    }

    /// Read-only legacy key (`consent_notice_shown` after the snake-case conversion); never encoded.
    private enum LegacyKeys: String, CodingKey { case consentNoticeShown }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
    private static func clampThreads(_ v: Int) -> Int {
        clamp(v, MachineProfile.batchThreadRange.lowerBound, MachineProfile.batchThreadRange.upperBound)
    }

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
        finalThreads = try c.decodeIfPresent(Int.self, forKey: .finalThreads).map(Self.clampThreads)
        voiceProcessing = try c.decodeIfPresent(Bool.self, forKey: .voiceProcessing) ?? voiceProcessing
        fillerRemoval = try c.decodeIfPresent(Bool.self, forKey: .fillerRemoval) ?? fillerRemoval
        countdownSeconds = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? countdownSeconds, 0, 30)
        disconnectGraceSeconds = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .disconnectGraceSeconds) ?? disconnectGraceSeconds, 5, 300)
        startOnModelMatch = try c.decodeIfPresent(Bool.self, forKey: .startOnModelMatch) ?? startOnModelMatch
        audioRetentionDays = try c.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? audioRetentionDays
        shortcuts = try c.decodeIfPresent(Shortcuts.self, forKey: .shortcuts) ?? shortcuts
        liveSummaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveSummaryEnabled) ?? liveSummaryEnabled
        liveSummaryIntervalSeconds = Self.clamp(
            try c.decodeIfPresent(Int.self, forKey: .liveSummaryIntervalSeconds) ?? liveSummaryIntervalSeconds,
            Self.liveSummaryIntervalRange.lowerBound, Self.liveSummaryIntervalRange.upperBound)
        let model = (try c.decodeIfPresent(String.self, forKey: .liveSummaryModel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        liveSummaryModel = model.isEmpty ? Self.defaultLiveSummaryModel : model
        // Backward compatibility: settings written while the consent notice existed carry `consent_notice_shown`.
        // Either key being true means the first run is done; only `first_run_completed` is written.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let legacyShown = try legacy.decodeIfPresent(Bool.self, forKey: .consentNoticeShown) ?? false
        firstRunCompleted = (try c.decodeIfPresent(Bool.self, forKey: .firstRunCompleted) ?? false) || legacyShown
    }
}
