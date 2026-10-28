import Foundation

/// One homework item of the live summary. `owner` is nil unless the utterances named one.
public struct LiveSummaryTodo: Codable, Equatable, Sendable {
    public var text: String
    public var owner: String?

    public init(text: String, owner: String?) {
        self.text = text; self.owner = owner
    }
}

/// What the model returns (the same shape as `LiveSummarySchema.json`).
public struct LiveSummaryOutput: Codable, Equatable, Sendable {
    public var now: String
    public var decisions: [String]
    public var todos: [LiveSummaryTodo]

    public init(now: String, decisions: [String], todos: [LiveSummaryTodo]) {
        self.now = now; self.decisions = decisions; self.todos = todos
    }
}

/// The live summary card's state, saved as `transcripts/<id>/live-summary.json`.
/// `consumedThrough` is the end second of the newest utterance already reflected.
public struct LiveSummaryState: Codable, Equatable, Sendable {
    public var now: String
    public var decisions: [String]
    public var todos: [LiveSummaryTodo]
    public var consumedThrough: Double
    public var updatedAt: Date?

    public static let listLimit = 50
    public static let nowLimit = 60
    public static let empty = LiveSummaryState(now: "", decisions: [], todos: [], consumedThrough: 0, updatedAt: nil)

    public init(now: String, decisions: [String], todos: [LiveSummaryTodo], consumedThrough: Double, updatedAt: Date?) {
        self.now = now; self.decisions = decisions; self.todos = todos
        self.consumedThrough = consumedThrough; self.updatedAt = updatedAt
    }

    /// The part sent back to the model as the previous state.
    public var output: LiveSummaryOutput { LiveSummaryOutput(now: now, decisions: decisions, todos: todos) }

    /// Cleans the model output (trim, drop blanks and duplicates, keep the newest `listLimit`, cap `now`)
    /// and never moves `consumedThrough` backwards.
    public func applying(_ output: LiveSummaryOutput, consumedThrough: Double, at: Date) -> LiveSummaryState {
        var seen = Set<String>()
        let decisions = output.decisions.map(Self.trim).filter { !$0.isEmpty && seen.insert($0).inserted }
        var seenTodos = Set<String>()
        let todos = output.todos.compactMap { t -> LiveSummaryTodo? in
            let text = Self.trim(t.text)
            guard !text.isEmpty, seenTodos.insert(text).inserted else { return nil }
            let owner = t.owner.map(Self.trim).flatMap { $0.isEmpty ? nil : $0 }
            return LiveSummaryTodo(text: text, owner: owner)
        }
        return LiveSummaryState(now: String(Self.trim(output.now).prefix(Self.nowLimit)),
                                decisions: Array(decisions.suffix(Self.listLimit)),
                                todos: Array(todos.suffix(Self.listLimit)),
                                consumedThrough: max(self.consumedThrough, consumedThrough),
                                updatedAt: at)
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Reads and writes `transcripts/<id>/live-summary.json`.
public struct LiveSummaryStore: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    /// nil when the file does not exist; throws when it cannot be read or decoded.
    public func load(_ id: MeetingID) throws -> LiveSummaryState? {
        let url = paths.liveSummaryFile(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AutoNoteJSON.decoder().decode(LiveSummaryState.self, from: Data(contentsOf: url))
    }

    /// Atomic write (temporary file and rename), creating the transcripts folder if needed.
    public func save(_ s: LiveSummaryState, for id: MeetingID) throws {
        try FileManager.default.createDirectory(at: paths.transcriptsDirectory(id), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(s).write(to: paths.liveSummaryFile(id), options: .atomic)
    }
}
