import Foundation
import os

/// Who set a question's `asked`: the live summary (`model`) or the person by hand (`user`). A `user` mark is never
/// overridden by the model.
public enum LiveQuestionMarker: String, Codable, Sendable {
    case model, user
}

/// One thing the person wants to ask in the meeting. The text belongs to the person: the model only ever returns ids.
public struct LiveQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var asked: Bool
    public var askedBy: LiveQuestionMarker?

    public init(id: String, text: String, asked: Bool = false, askedBy: LiveQuestionMarker? = nil) {
        self.id = id; self.text = text; self.asked = asked; self.askedBy = askedBy
    }

    private enum CodingKeys: String, CodingKey { case id, text, asked, askedBy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        asked = try c.decodeIfPresent(Bool.self, forKey: .asked) ?? false
        askedBy = try c.decodeIfPresent(LiveQuestionMarker.self, forKey: .askedBy)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(asked, forKey: .asked)
        try c.encode(askedBy, forKey: .askedBy)
    }
}

/// What the model is sent of one undecided question.
public struct LiveQuestionPrompt: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var text: String

    public init(id: String, text: String) { self.id = id; self.text = text }
}

/// A change the person makes to the questions.
public enum LiveQuestionEdit: Equatable, Sendable {
    case add(String)
    case remove(id: String)
    case setAsked(id: String, Bool)
    case rename(id: String, String)
}

/// Where a list of questions lives: the draft written before recording, or one meeting's.
public enum LiveQuestionScope: Hashable, Sendable {
    case draft
    case meeting(MeetingID)
}

/// The questions of one scope, saved as `transcripts/<id>/questions.json` or the draft `pending-questions.json`.
public struct LiveQuestionList: Codable, Equatable, Sendable {
    public var items: [LiveQuestion]

    public static let limit = 30
    public static let textLimit = 200
    public static let empty = LiveQuestionList(items: [])

    public init(items: [LiveQuestion]) { self.items = items }

    public var canAdd: Bool { items.count < Self.limit }
    public var askedCount: Int { items.filter(\.asked).count }

    /// Not asked yet and not set by hand: only these are sent to the model.
    public var pendingForModel: [LiveQuestionPrompt] {
        items.filter { !$0.asked && $0.askedBy != .user }.map { LiveQuestionPrompt(id: $0.id, text: $0.text) }
    }

    /// Trimmed and capped at `textLimit`; false for a blank text or a full list.
    @discardableResult public mutating func add(_ text: String, id: String) -> Bool {
        let clean = Self.clean(text)
        guard !clean.isEmpty, canAdd else { return false }
        items.append(LiveQuestion(id: id, text: clean))
        return true
    }

    public mutating func remove(_ id: String) { items.removeAll { $0.id == id } }

    /// A hand mark (`askedBy = user`), which the model never overrides.
    public mutating func setAsked(_ id: String, _ asked: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].asked = asked
        items[i].askedBy = .user
    }

    /// A blank text leaves the item unchanged.
    public mutating func rename(_ id: String, to text: String) {
        let clean = Self.clean(text)
        guard !clean.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = clean
    }

    /// The model's result: only ever marks asked, never an item set by hand; unknown ids are ignored.
    public mutating func markAskedByModel(_ ids: [String]) {
        let ids = Set(ids)
        for i in items.indices where ids.contains(items[i].id) && !items[i].asked && items[i].askedBy != .user {
            items[i].asked = true
            items[i].askedBy = .model
        }
    }

    /// Appends up to the limit; an id already in the list is replaced by a fresh one from `makeID`.
    public mutating func append(contentsOf other: [LiveQuestion], makeID: () -> String) {
        for var q in other where canAdd {
            q.id = uniqueID(q.id, makeID: makeID)
            items.append(q)
        }
    }

    /// Applies one edit; a new item gets a fresh id from `makeID` (drawn again on a collision).
    public mutating func apply(_ edit: LiveQuestionEdit, makeID: () -> String) {
        switch edit {
        case .add(let text): add(text, id: uniqueID(makeID(), makeID: makeID))
        case .remove(let id): remove(id)
        case .setAsked(let id, let asked): setAsked(id, asked)
        case .rename(let id, let text): rename(id, to: text)
        }
    }

    private func uniqueID(_ candidate: String, makeID: () -> String) -> String {
        var id = candidate
        var tries = 0
        while id.isEmpty || items.contains(where: { $0.id == id }) {
            tries += 1
            id = tries < 20 ? makeID() : "\(candidate)-\(items.count + tries)"
        }
        return id
    }

    private static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit))
    }
}

/// One list after a change.
public struct LiveQuestionsUpdate: Equatable, Sendable {
    public var scope: LiveQuestionScope
    public var items: [LiveQuestion]

    public init(scope: LiveQuestionScope, items: [LiveQuestion]) { self.scope = scope; self.items = items }
}

/// Reads and writes the question lists.
public protocol LiveQuestionsStorage: Sendable {
    /// nil when there is no file; throws when it cannot be read or decoded.
    func load(_ scope: LiveQuestionScope) throws -> LiveQuestionList?
    func save(_ list: LiveQuestionList, _ scope: LiveQuestionScope) throws
}

/// `transcripts/<id>/questions.json` (next to `live-summary.json`) and `<data>/pending-questions.json`. Atomic writes.
public struct LiveQuestionsFileStorage: LiveQuestionsStorage {
    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func load(_ scope: LiveQuestionScope) throws -> LiveQuestionList? {
        let url = file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AutoNoteJSON.decoder().decode(LiveQuestionList.self, from: Data(contentsOf: url))
    }

    public func save(_ list: LiveQuestionList, _ scope: LiveQuestionScope) throws {
        let url = file(scope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(list).write(to: url, options: .atomic)
    }

    private func file(_ scope: LiveQuestionScope) -> URL {
        switch scope {
        case .draft: paths.pendingQuestionsFile
        case .meeting(let id): paths.questionsFile(id)
        }
    }
}

/// Every read and write of the questions, one at a time: the person's edits, the draft moving into a recording, and
/// the live summary's marks. Each change re-reads the file first, so a mark from a call that was in flight while the
/// person edited lands on the list as it is now. Unreadable files read as empty (and are overwritten by the next edit).
public actor LiveQuestionsRepository: LiveQuestionsPort {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "LiveQuestions")

    private let storage: any LiveQuestionsStorage
    private let makeID: @Sendable () -> String
    private var subscribers: [UUID: AsyncStream<LiveQuestionsUpdate>.Continuation] = [:]

    public init(storage: any LiveQuestionsStorage, makeID: @escaping @Sendable () -> String = LiveQuestionsRepository.randomID) {
        self.storage = storage
        self.makeID = makeID
    }

    /// Eight lowercase hex characters.
    public static func randomID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    public func list(_ scope: LiveQuestionScope) -> [LiveQuestion] { read(scope).items }

    @discardableResult public func apply(_ edit: LiveQuestionEdit, to scope: LiveQuestionScope) -> [LiveQuestion] {
        var list = read(scope)
        let before = list
        let makeID = self.makeID
        list.apply(edit, makeID: { makeID() })
        guard list != before else { return list.items }
        write(list, scope)
        return list.items
    }

    /// Moves the draft into the meeting that just started recording and empties the draft. Nothing when the draft is empty.
    public func adoptDraft(into id: MeetingID) {
        let draft = read(.draft)
        guard !draft.items.isEmpty else { return }
        var meeting = read(.meeting(id))
        let makeID = self.makeID
        meeting.append(contentsOf: draft.items, makeID: { makeID() })
        write(meeting, .meeting(id))
        write(.empty, .draft)
        Self.logger.notice("\(id.rawValue, privacy: .public): \(draft.items.count, privacy: .public) questions moved from the draft")
    }

    /// The undecided questions of a meeting, for one live summary call.
    public func pendingForModel(_ id: MeetingID) -> [LiveQuestionPrompt] { read(.meeting(id)).pendingForModel }

    /// The live summary's result, applied to the file as it is now.
    public func markAskedByModel(_ ids: [String], in id: MeetingID) {
        guard !ids.isEmpty else { return }
        var list = read(.meeting(id))
        let before = list
        list.markAskedByModel(ids)
        guard list != before else { return }
        write(list, .meeting(id))
    }

    public func updates() -> AsyncStream<LiveQuestionsUpdate> {
        let (stream, continuation) = AsyncStream<LiveQuestionsUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let key = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        subscribers[key] = continuation
        return stream
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    private func read(_ scope: LiveQuestionScope) -> LiveQuestionList {
        do {
            return try storage.load(scope) ?? .empty
        } catch {
            Self.logger.error("questions unreadable (\(Self.name(scope), privacy: .public)): \(String(describing: type(of: error)), privacy: .public)")
            return .empty
        }
    }

    private func write(_ list: LiveQuestionList, _ scope: LiveQuestionScope) {
        do {
            try storage.save(list, scope)
        } catch {
            Self.logger.error("questions not saved (\(Self.name(scope), privacy: .public)): \(String(describing: type(of: error)), privacy: .public)")
        }
        let update = LiveQuestionsUpdate(scope: scope, items: list.items)
        for c in subscribers.values { c.yield(update) }
    }

    private static func name(_ scope: LiveQuestionScope) -> String {
        switch scope {
        case .draft: "draft"
        case .meeting(let id): id.rawValue
        }
    }
}
