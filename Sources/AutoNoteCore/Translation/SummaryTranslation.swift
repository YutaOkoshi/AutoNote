import Foundation

/// One translated summary text (a live summary's topic, decision or homework; a minutes item's text), tied to its
/// original by `TranslationKey.textHash`, wherever the text sits.
public struct SummaryTranslatedText: Codable, Equatable, Hashable, Sendable {
    public var sourceHash: String
    public var sourceLanguage: TranslationLanguage
    public var targetLanguage: TranslationLanguage
    /// Empty when the model gave nothing usable: remembered so the text is not tried again on every update.
    public var text: String

    public init(sourceHash: String, sourceLanguage: TranslationLanguage, targetLanguage: TranslationLanguage,
                text: String) {
        self.sourceHash = sourceHash
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.text = text
    }
}

/// `transcripts/<id>/live-summary-translation.json` and `minutes-translation.json` (spec 2026-11-19 保存): the
/// translations of a meeting's summary texts, next to (never inside) `live-summary.json` and `minutes.json`.
/// Each entry is looked up by its original's hash, so an item whose text changed is simply not found (and is
/// translated again), and one that only moved keeps its translation.
public struct SummaryTranslationDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// `TranslationModel.name` and the pinned revision of the newest run.
    public var model: String
    public var modelRevision: String
    /// The `translation_target` of the newest run.
    public var target: TranslationTarget
    public var updatedAt: Date
    public var entries: [SummaryTranslatedText]

    public init(model: String, modelRevision: String, target: TranslationTarget, updatedAt: Date,
                entries: [SummaryTranslatedText] = [], version: Int = Self.currentVersion) {
        self.version = version
        self.model = model
        self.modelRevision = modelRevision
        self.target = target
        self.updatedAt = updatedAt
        self.entries = entries
    }

    /// The translation of `text`, nil when there is none (or the model gave nothing).
    public func translation(of text: String) -> String? {
        let hash = TranslationKey.textHash(text)
        guard let entry = entries.last(where: { $0.sourceHash == hash }), !entry.text.isEmpty else { return nil }
        return entry.text
    }

    func hasEntry(for text: String, target: TranslationLanguage) -> Bool {
        let hash = TranslationKey.textHash(text)
        return entries.contains { $0.sourceHash == hash && $0.targetLanguage == target }
    }

    /// Only the entries of `texts` (the summary as it is now) stay, so the file never grows with old versions.
    mutating func keepOnly(_ texts: [String]) {
        let hashes = Set(texts.map(TranslationKey.textHash))
        entries.removeAll { !hashes.contains($0.sourceHash) }
    }
}

/// Which of the two summaries a document belongs to.
public enum SummaryKind: String, Sendable, CaseIterable {
    case live, minutes

    var fileName: String { self == .live ? "live-summary-translation.json" : "minutes-translation.json" }
}

/// One summary text to translate and its direction.
public struct SummaryTranslationItem: Equatable, Sendable {
    public var text: String
    public var source: TranslationLanguage
    public var target: TranslationLanguage

    public init(text: String, source: TranslationLanguage, target: TranslationLanguage) {
        self.text = text
        self.source = source
        self.target = target
    }
}

/// The summaries' translation (spec 2026-11-19): the summary is written in the meeting's language first, then its
/// texts are translated one by one with the on-device model. The translation is never fed back to a summary.
public enum SummaryTranslation {
    // MARK: - What is translated (spec 訳す対象)

    /// The live summary: the topic, the decisions and the homework texts (not the owners). The topic goes first, as
    /// the items lean on it (`liveContext`).
    public static func liveTexts(_ s: LiveSummaryState) -> [String] {
        unique([s.now] + s.decisions + s.todos.map(\.text))
    }

    /// The minutes in the note's section order, except that the summary comes before the title: the title leans on
    /// the summary, and every other text on both (`minutesContext`). Owners, dates, times, attendees, suggested terms
    /// and the diagram are not translated.
    public static func minutesTexts(_ m: MinutesOutput) -> [String] {
        var texts = m.summary + [m.title]
        for a in m.agenda { texts += [a.title, a.body] }
        texts += m.keyPoints.map(\.text)
        texts += m.decisions.map(\.text)
        texts += m.nextActions.map(\.text)
        for q in m.questions { texts += [q.question, q.answer ?? ""] }
        texts += m.deadlines.map(\.description)
        texts += m.followUps.map(\.text)
        for r in m.risks { texts += [r.description, r.mitigation ?? ""] }
        texts += m.insights.map(\.text)
        return unique(texts)
    }

    // MARK: - Context (Lead's call, open to change)

    /// The texts a minutes text is translated with as context, oldest first: the summary's paragraphs, then the
    /// title (nearest). A text only lends context once it is translated, and never to itself (`history`).
    public static func minutesContext(_ m: MinutesOutput) -> [String] {
        m.summary + [m.title]
    }

    /// The live summary's context: the items in order, then the topic (nearest); the last `historyLimit` that are
    /// translated are the topic and the latest items.
    public static func liveContext(_ s: LiveSummaryState) -> [String] {
        s.decisions + s.todos.map(\.text) + [s.now]
    }

    /// The history pairs `text` is translated with: the last `PlamoPrompt.historyLimit` texts of `context` other than
    /// `text` that `document` holds a non-empty translation of. Only a prompt's history, never part of the output;
    /// the stored entry stays keyed by `text` alone, so a changed context translates nothing again.
    public static func history(for text: String, context: [String],
                               document: SummaryTranslationDocument) -> [TranslationPair] {
        let pairs: [TranslationPair] = context.compactMap { c in
            guard c != text, let entry = document.entries.first(where: { $0.sourceHash == TranslationKey.textHash(c) }),
                  !entry.text.isEmpty else { return nil }
            return TranslationPair(source: c, sourceLanguage: entry.sourceLanguage, translation: entry.text,
                                   targetLanguage: entry.targetLanguage)
        }
        return Array(pairs.suffix(PlamoPrompt.historyLimit))
    }

    private static func unique(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Direction (spec 翻訳先)

    /// Lead's call, open to change: the summaries share `translation_target`. A fixed target is that language, `auto`
    /// the other one; nil when that is the summary's own language (nothing to translate).
    public static func targetLanguage(summary: TranslationLanguage, setting: TranslationTarget) -> TranslationLanguage? {
        let target: TranslationLanguage = switch setting {
        case .auto: summary.opposite
        case .ja: .ja
        case .en: .en
        }
        return target == summary ? nil : target
    }

    /// The target for a summary made of `texts`, its language read from the texts themselves; nil when there is
    /// nothing to translate.
    public static func targetLanguage(for texts: [String], setting: TranslationTarget) -> TranslationLanguage? {
        guard texts.contains(where: { TranslationLanguageDetector.language(of: $0) != nil }) else { return nil }
        return targetLanguage(summary: SummaryLanguagePolicy.decide(texts), setting: setting)
    }

    /// The texts of `texts` still to translate into `target`, in order: one already in `target` or without letters
    /// is left out, and so is one `document` already holds.
    public static func pending(_ texts: [String], target: TranslationLanguage,
                               document: SummaryTranslationDocument?) -> [SummaryTranslationItem] {
        var seen = Set<String>()
        return texts.compactMap { text in
            guard seen.insert(text).inserted,
                  let source = TranslationLanguageDetector.language(of: text), source != target,
                  document?.hasEntry(for: text, target: target) != true else { return nil }
            return SummaryTranslationItem(text: text, source: source, target: target)
        }
    }

    // MARK: - Running

    /// Translates what `pending` finds, updating `document` after each text and calling `checkpoint` with it (to save
    /// it and broadcast). Entries of texts no longer in `texts` are dropped first. `.suspend` stops the run.
    /// - Returns: whether every pending text was done.
    public static func run(_ document: inout SummaryTranslationDocument, texts: [String], context: [String] = [],
                           target: TranslationLanguage,
                           translator: UtteranceTranslator,
                           checkpoint: (SummaryTranslationDocument) async -> TranscriptTranslation.Checkpoint)
        async throws -> Bool {
        document.keepOnly(texts)
        for item in pending(texts, target: target, document: document) {
            try Task.checkCancellation()
            let text = try await translator.translateSummary(item.text, from: item.source, to: item.target,
                                                             history: history(for: item.text, context: context,
                                                                              document: document))
            document.entries.append(SummaryTranslatedText(sourceHash: TranslationKey.textHash(item.text),
                                                          sourceLanguage: item.source, targetLanguage: item.target,
                                                          text: text))
            if await checkpoint(document) == .suspend { return false }
        }
        return true
    }
}

extension UtteranceTranslator {
    /// A summary text, line by line (a paragraph break stays where it was), with a larger cap than an utterance's
    /// (`PlamoPrompt.summaryMaxTokens`). `history` is the same summary's context (`SummaryTranslation.history`),
    /// given to every line; it is only the prompt's, never translated into the output. Blank lines are kept.
    public func translateSummary(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage,
                                 history: [TranslationPair] = []) async throws -> String {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(line)
                continue
            }
            out.append(try await translate(line, from: source, to: target, history: history,
                                           maxTokens: PlamoPrompt.summaryMaxTokens(for: line)))
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PlamoPrompt {
    /// The generation cap for a summary line: a paragraph of the minutes can run far longer than an utterance, so
    /// the cap is the utterance's rule with a higher ceiling (still inside the 4,096-token context with the prompt).
    public static func summaryMaxTokens(for text: String) -> Int {
        min(1_536, max(64, text.count * 2 + 32))
    }
}
