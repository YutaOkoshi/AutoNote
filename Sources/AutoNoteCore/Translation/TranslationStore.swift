import CryptoKit
import Foundation

/// One translated utterance of the final transcript.
public struct TranslatedUtterance: Codable, Equatable, Hashable, Sendable {
    /// The utterance's index in the final transcript's `utterances`.
    public var index: Int
    /// The first 16 hex digits of the SHA-256 of the original text: the entry is shown only on the line it was made
    /// from (`TranslationKey.textHash`).
    public var sourceHash: String
    public var sourceLanguage: TranslationLanguage
    public var targetLanguage: TranslationLanguage
    public var text: String

    public init(index: Int, sourceHash: String, sourceLanguage: TranslationLanguage,
                targetLanguage: TranslationLanguage, text: String) {
        self.index = index
        self.sourceHash = sourceHash
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.text = text
    }
}

/// `transcripts/<id>/translation.json`: the final transcript's translation (spec 8). Written next to the
/// transcript, never into it.
public struct TranslationDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// `TranslationModel.name` and the pinned revision it ran with.
    public var model: String
    public var modelRevision: String
    public var target: TranslationTarget
    public var createdAt: Date
    /// `TranslationKey.digest` of the final transcript it was made from: a different digest means the transcript
    /// was redone and this translation is stale.
    public var sourceDigest: String
    /// The utterances counted for progress (those with a direction under `target`).
    public var total: Int
    /// How many of those are done (an empty model output counts as done, with no entry).
    public var processed: Int
    /// The transcript index the next run starts at (everything before it is done).
    public var nextIndex: Int
    /// False while a run is under way or was interrupted (a later 「翻訳する」 continues from `nextIndex`).
    public var complete: Bool
    public var entries: [TranslatedUtterance]

    public init(model: String, modelRevision: String, target: TranslationTarget, createdAt: Date, sourceDigest: String,
                total: Int, processed: Int = 0, nextIndex: Int = 0, complete: Bool, entries: [TranslatedUtterance],
                version: Int = Self.currentVersion) {
        self.version = version
        self.model = model
        self.modelRevision = modelRevision
        self.target = target
        self.createdAt = createdAt
        self.sourceDigest = sourceDigest
        self.total = total
        self.processed = processed
        self.nextIndex = nextIndex
        self.complete = complete
        self.entries = entries
    }
}

/// One translated line of the live transcript.
public struct LiveTranslatedLine: Codable, Equatable, Hashable, Sendable {
    /// `TranslationKey.live(_:)` of the confirmed utterance.
    public var key: String
    public var sourceLanguage: TranslationLanguage
    public var targetLanguage: TranslationLanguage
    public var text: String

    public init(key: String, sourceLanguage: TranslationLanguage, targetLanguage: TranslationLanguage, text: String) {
        self.key = key
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.text = text
    }
}

/// `transcripts/<id>/live-translation.json`: the translations made while recording (spec 8). Deleted once the
/// final translation is complete.
public struct LiveTranslationDocument: Codable, Equatable, Sendable {
    public var model: String
    public var target: TranslationTarget
    public var lines: [LiveTranslatedLine]

    public init(model: String, target: TranslationTarget, lines: [LiveTranslatedLine]) {
        self.model = model
        self.target = target
        self.lines = lines
    }
}

/// How translations are tied to the original lines.
public enum TranslationKey {
    /// SHA-256 over every utterance's start (ms), speaker and text, in order: any change to the final transcript
    /// changes it.
    public static func digest(_ utterances: [Utterance]) -> String {
        var hasher = SHA256()
        for u in utterances {
            hasher.update(data: Data("\(Int((u.start.seconds * 1000).rounded()))\u{1F}\(u.speaker.rawValue)\u{1F}\(u.text)\u{1E}".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The first 16 hex digits of the SHA-256 of `text`.
    public static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A confirmed live utterance: start (ms), speaker and the text's hash. Stable while the line stays confirmed.
    public static func live(_ u: Utterance) -> String {
        "\(Int((u.start.seconds * 1000).rounded())):\(u.speaker.rawValue):\(textHash(u.text))"
    }
}

/// Reads and writes the translation files of a meeting (the transcript's two and the summaries' two). Writes are atomic; the transcript files are never
/// opened for writing.
public struct TranslationStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func translationFile(_ id: MeetingID) -> URL {
        paths.transcriptsDirectory(id).appending(path: "translation.json")
    }

    public func liveTranslationFile(_ id: MeetingID) -> URL {
        paths.transcriptsDirectory(id).appending(path: "live-translation.json")
    }

    /// nil when there is none; a file that cannot be decoded is treated as none (it is rewritten on the next run).
    public func load(_ id: MeetingID) -> TranslationDocument? {
        read(TranslationDocument.self, from: translationFile(id))
    }

    public func save(_ document: TranslationDocument, for id: MeetingID) throws {
        try write(document, to: translationFile(id))
    }

    public func loadLive(_ id: MeetingID) -> LiveTranslationDocument? {
        read(LiveTranslationDocument.self, from: liveTranslationFile(id))
    }

    public func saveLive(_ document: LiveTranslationDocument, for id: MeetingID) throws {
        try write(document, to: liveTranslationFile(id))
    }

    public func deleteLive(_ id: MeetingID) {
        try? FileManager.default.removeItem(at: liveTranslationFile(id))
    }

    /// `live-summary-translation.json` or `minutes-translation.json`.
    public func summaryTranslationFile(_ id: MeetingID, _ kind: SummaryKind) -> URL {
        paths.transcriptsDirectory(id).appending(path: kind.fileName)
    }

    /// nil when there is none; a file that cannot be decoded is treated as none (it is rewritten on the next run).
    public func loadSummary(_ id: MeetingID, _ kind: SummaryKind) -> SummaryTranslationDocument? {
        read(SummaryTranslationDocument.self, from: summaryTranslationFile(id, kind))
    }

    public func saveSummary(_ document: SummaryTranslationDocument, _ kind: SummaryKind, for id: MeetingID) throws {
        try write(document, to: summaryTranslationFile(id, kind))
    }

    /// `minutes.json`, read only; nil when missing or unreadable.
    public func minutes(_ id: MeetingID) -> MinutesOutput? {
        read(MinutesOutput.self, from: paths.minutesFile(id))
    }

    /// `live-summary.json`, read only; nil when missing or unreadable.
    public func liveSummary(_ id: MeetingID) -> LiveSummaryState? {
        read(LiveSummaryState.self, from: paths.liveSummaryFile(id))
    }

    /// The final transcript (`final.json`), read only.
    public func finalTranscript(_ id: MeetingID) -> Transcript? {
        read(Transcript.self, from: paths.transcriptFile(id, .final))
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? AutoNoteJSON.decoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(value).write(to: url, options: .atomic)
    }
}

/// What a meeting's stored translation means for its current final transcript.
public enum TranslationStatus: Equatable, Sendable {
    /// No translation, or none for this transcript's content and nothing to continue.
    case none
    /// A run stopped part way (`done` of `total`) for this very transcript; 「翻訳する」 continues it.
    case partial(done: Int, total: Int)
    /// Complete for the current transcript.
    case complete
    /// Made from an earlier version of the transcript: not shown; 「訳し直す」.
    case stale

    public static func of(_ document: TranslationDocument?, transcript: Transcript?) -> TranslationStatus {
        guard let document, let transcript else { return .none }
        guard document.sourceDigest == TranslationKey.digest(transcript.utterances) else { return .stale }
        return document.complete ? .complete : .partial(done: document.processed, total: document.total)
    }
}
