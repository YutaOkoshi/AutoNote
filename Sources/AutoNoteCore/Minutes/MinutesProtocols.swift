import Foundation

public struct SummaryInput: Codable, Equatable, Sendable {
    public var instructions: String
    public var terms: [String]
    public var bookmarks: [Bookmark]
    public var transcript: Transcript
    public var language: Language

    public init(instructions: String, terms: [String], bookmarks: [Bookmark], transcript: Transcript, language: Language) {
        self.instructions = instructions; self.terms = terms; self.bookmarks = bookmarks
        self.transcript = transcript; self.language = language
    }
}

public protocol Summarizer: Sendable {
    func summarize(_ input: SummaryInput) async throws -> MinutesOutput
}

public enum StageName {
    public static let transcribe = "transcribe"
    public static let summarize = "summarize"
    public static let writeVault = "write_vault"
    public static let updateIndex = "update_index"
    public static let automations = "automations"
    public static let all: [String] = [transcribe, summarize, writeVault, updateIndex, automations]
}

public enum JobState: String, Codable, Sendable {
    case pending, running, waiting, failed, done
}

public struct Job: Codable, Equatable, Sendable {
    public var id: String
    public var meeting: MeetingID
    public var stages: [String]
    public var completedStages: [String]
    public var state: JobState
    public var attempts: Int
    public var lastError: String?
    public var notBefore: Date?
    public var createdAt: Date
    /// +1 per regeneration; Automations dedupe key is `"\(meeting.rawValue):\(generation)"`.
    public var generation: Int
    public var transcriptEngine: String?
    public var summaryFailure: String?
    public var overwriteApproved: Bool
    /// Hourly rate-limit summarize rounds so far (nil when none); reset by a successful summarize.
    public var rateLimitRounds: Int?

    public init(id: String, meeting: MeetingID, stages: [String], completedStages: [String], state: JobState,
                attempts: Int, lastError: String?, notBefore: Date?, createdAt: Date,
                generation: Int = 0, transcriptEngine: String? = nil, summaryFailure: String? = nil,
                overwriteApproved: Bool = false, rateLimitRounds: Int? = nil) {
        self.id = id; self.meeting = meeting; self.stages = stages; self.completedStages = completedStages
        self.state = state; self.attempts = attempts; self.lastError = lastError; self.notBefore = notBefore
        self.createdAt = createdAt; self.generation = generation; self.transcriptEngine = transcriptEngine
        self.summaryFailure = summaryFailure; self.overwriteApproved = overwriteApproved
        self.rateLimitRounds = rateLimitRounds
    }

    /// First stage not yet completed.
    public var nextStage: String? { stages.first { !completedStages.contains($0) } }

    private enum CodingKeys: String, CodingKey {
        case id, meeting, stages, completedStages, state, attempts, lastError, notBefore, createdAt
        case generation, transcriptEngine, summaryFailure, overwriteApproved, rateLimitRounds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        meeting = try c.decode(MeetingID.self, forKey: .meeting)
        stages = try c.decode([String].self, forKey: .stages)
        completedStages = try c.decode([String].self, forKey: .completedStages)
        state = try c.decode(JobState.self, forKey: .state)
        attempts = try c.decode(Int.self, forKey: .attempts)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        notBefore = try c.decodeIfPresent(Date.self, forKey: .notBefore)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        transcriptEngine = try c.decodeIfPresent(String.self, forKey: .transcriptEngine)
        summaryFailure = try c.decodeIfPresent(String.self, forKey: .summaryFailure)
        overwriteApproved = try c.decodeIfPresent(Bool.self, forKey: .overwriteApproved) ?? false
        rateLimitRounds = try c.decodeIfPresent(Int.self, forKey: .rateLimitRounds)
    }
}

public struct StageContext: Sendable {
    public var paths: AppPaths
    public var settings: Settings
    public var manifests: ManifestStore
    public var now: @Sendable () -> Date
    public var reportProgress: @Sendable (Double) -> Void

    public init(paths: AppPaths, settings: Settings, manifests: ManifestStore,
                now: @escaping @Sendable () -> Date, reportProgress: @escaping @Sendable (Double) -> Void) {
        self.paths = paths; self.settings = settings; self.manifests = manifests
        self.now = now; self.reportProgress = reportProgress
    }
}

public protocol QueueStage: Sendable {
    var name: String { get }
    func run(_ job: inout Job, context: StageContext) async throws
}
