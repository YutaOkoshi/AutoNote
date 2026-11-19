import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "UtteranceTranslator")

/// One utterance to translate and its direction.
public struct TranslationItem: Equatable, Sendable {
    public var index: Int
    public var text: String
    public var source: TranslationLanguage
    public var target: TranslationLanguage

    public init(index: Int, text: String, source: TranslationLanguage, target: TranslationLanguage) {
        self.index = index
        self.text = text
        self.source = source
        self.target = target
    }
}

/// n of total, for the meeting screen.
public struct TranslationProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// Translates one utterance through `TextCompleting` (spec 4): the PFML3 prompt, greedy, the two stop strings and
/// the per-utterance cap. The runtime must already hold the model.
public struct UtteranceTranslator: Sendable {
    private let completer: any TextCompleting

    public init(completer: any TextCompleting) { self.completer = completer }

    /// The cleaned translation; empty when the model produced nothing usable. A prompt longer than the model's
    /// context (`LlamaError.promptTooLong`) is retried with fewer history pairs, oldest dropped first; an utterance
    /// too long even alone is left untranslated (empty) rather than failing the whole run.
    /// `maxTokens` replaces the per-utterance cap (`PlamoPrompt.maxTokens`) when given.
    public func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage,
                          history: [TranslationPair], maxTokens: Int? = nil) async throws -> String {
        var history = Array(history.suffix(PlamoPrompt.historyLimit))
        while true {
            let prompt = PlamoPrompt.build(text: text, source: source, target: target, history: history)
            do {
                let raw = try await completer.complete(prompt: prompt, stop: PlamoPrompt.stopStrings,
                                                       maxTokens: maxTokens ?? PlamoPrompt.maxTokens(for: text))
                return PlamoPrompt.cleaned(raw)
            } catch LlamaError.promptTooLong(let tokens, let limit) {
                guard !history.isEmpty else {
                    logger.notice("utterance left untranslated: \(tokens, privacy: .public) tokens > \(limit, privacy: .public)")
                    return ""
                }
                history.removeFirst()
            }
        }
    }
}

/// The final transcript's translation as a resumable run.
public enum TranscriptTranslation {
    /// The utterances to translate under `target`, in order: markers, lines without letters and lines already in a
    /// fixed target language are left out (spec 5).
    public static func plan(_ utterances: [Utterance], target: TranslationTarget) -> [TranslationItem] {
        utterances.enumerated().compactMap { index, u in
            guard !LiveFeed.isMarker(u),
                  let d = TranslationLanguageDetector.direction(of: u.text, target: target) else { return nil }
            return TranslationItem(index: index, text: u.text, source: d.source, target: d.target)
        }
    }

    /// The history the item after `entries` carries: the last pairs already translated, with their originals.
    static func history(_ entries: [TranslatedUtterance], utterances: [Utterance]) -> [TranslationPair] {
        entries.suffix(PlamoPrompt.historyLimit).compactMap { e in
            guard utterances.indices.contains(e.index) else { return nil }
            return TranslationPair(source: utterances[e.index].text, sourceLanguage: e.sourceLanguage,
                                   translation: e.text, targetLanguage: e.targetLanguage)
        }
    }

    /// What a run does between two utterances.
    public enum Checkpoint: Sendable {
        /// Go on.
        case proceed
        /// Stop here (the document is saved as partial); the caller resumes later.
        case suspend
    }

    /// Translates the items of `plan` from `document.nextIndex` on, updating `document` after each one and calling
    /// `checkpoint` with it (to save it and report progress). `checkpoint` returning `.suspend` stops the run
    /// with the document partial. Throws `CancellationError` when cancelled; any runtime error is passed on.
    /// - Returns: whether the run finished (the document is then `complete`).
    public static func run(_ document: inout TranslationDocument, utterances: [Utterance], plan: [TranslationItem],
                           translator: UtteranceTranslator,
                           checkpoint: (TranslationDocument) async -> Checkpoint) async throws -> Bool {
        for item in plan where item.index >= document.nextIndex {
            try Task.checkCancellation()
            let history = history(document.entries, utterances: utterances)
            let text = try await translator.translate(item.text, from: item.source, to: item.target, history: history)
            if !text.isEmpty {
                document.entries.append(TranslatedUtterance(
                    index: item.index, sourceHash: TranslationKey.textHash(item.text), sourceLanguage: item.source,
                    targetLanguage: item.target, text: text))
            }
            document.processed += 1
            document.nextIndex = item.index + 1
            if await checkpoint(document) == .suspend { return false }
        }
        document.complete = true
        document.nextIndex = utterances.count
        return true
    }
}
