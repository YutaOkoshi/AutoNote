import Foundation

/// `autonote dev translate <transcript.json> [--target auto|ja|en] [--model <gguf>] [--minutes <minutes.json>]
/// [--live-summary <live-summary.json>]`.
public struct DevTranslateArguments: Equatable, Sendable {
    public static let usage = "usage: autonote dev translate <transcript.json> [--target auto|ja|en] [--model <gguf>] [--minutes <minutes.json>] [--live-summary <live-summary.json>]"

    public struct Invalid: Error, Equatable {}

    public var transcript: URL
    public var target: TranslationTarget = .auto
    /// A real GGUF to translate with the on-device runtime; nil = the deterministic fake.
    public var model: URL?
    /// `minutes.json` / `live-summary.json` whose texts are translated too (spec 2026-11-19).
    public var minutes: URL?
    public var liveSummary: URL?

    public static func parse(_ args: [String]) throws -> DevTranslateArguments {
        var transcript: URL?
        var target = TranslationTarget.auto
        var model: URL?
        var minutes: URL?
        var liveSummary: URL?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--target":
                guard i + 1 < args.count, let t = TranslationTarget(rawValue: args[i + 1]) else { throw Invalid() }
                target = t
                i += 2
            case "--model":
                guard i + 1 < args.count else { throw Invalid() }
                model = URL(filePath: args[i + 1])
                i += 2
            case "--minutes":
                guard i + 1 < args.count else { throw Invalid() }
                minutes = URL(filePath: args[i + 1])
                i += 2
            case "--live-summary":
                guard i + 1 < args.count else { throw Invalid() }
                liveSummary = URL(filePath: args[i + 1])
                i += 2
            case let a where a.hasPrefix("-"):
                throw Invalid()
            default:
                guard transcript == nil else { throw Invalid() }
                transcript = URL(filePath: args[i])
                i += 1
            }
        }
        guard let transcript else { throw Invalid() }
        return DevTranslateArguments(transcript: transcript, target: target, model: model, minutes: minutes,
                                     liveSummary: liveSummary)
    }
}

/// The one JSON line `dev translate` prints.
public struct DevTranslateLine: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var index: Int
        public var sourceLang: TranslationLanguage
        public var targetLang: TranslationLanguage
        public var text: String
    }

    public var target: TranslationTarget
    /// `fake` or the GGUF's file name.
    public var model: String
    /// Utterances in the transcript.
    public var utterances: Int
    public var entries: [Entry]
    /// Indexes left untranslated (markers, no letters, already in the target language, empty output).
    public var skipped: [Int]
    /// With `--minutes` / `--live-summary` only (absent otherwise).
    public var minutes: Summary?
    public var liveSummary: Summary?

    /// One summary's translation: its language, the target (absent when it is the summary's own) and each text.
    public struct Summary: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var source: String
            public var sourceLang: TranslationLanguage
            public var targetLang: TranslationLanguage
            public var text: String
        }

        public var summaryLang: TranslationLanguage
        public var targetLang: TranslationLanguage?
        public var entries: [Entry]

        static func make(_ texts: [String], context: [String], setting: TranslationTarget,
                         translator: UtteranceTranslator) async throws -> Summary {
            let language = SummaryLanguagePolicy.decide(texts)
            guard let target = SummaryTranslation.targetLanguage(for: texts, setting: setting) else {
                return Summary(summaryLang: language, targetLang: nil, entries: [])
            }
            var document = SummaryTranslationDocument(model: "", modelRevision: "", target: setting, updatedAt: Date())
            _ = try await SummaryTranslation.run(&document, texts: texts, context: context, target: target,
                                                 translator: translator) { _ in .proceed }
            let entries = SummaryTranslation.pending(texts, target: target, document: nil).compactMap { item -> Entry? in
                guard let text = document.translation(of: item.text) else { return nil }
                return Entry(source: item.text, sourceLang: item.source, targetLang: item.target, text: text)
            }
            return Summary(summaryLang: language, targetLang: target, entries: entries)
        }
    }

    /// Translates `transcript` (and the summaries given) with `completer` (already loaded by the caller).
    public static func make(transcript: Transcript, target: TranslationTarget, model: String,
                            completer: any TextCompleting, minutes: MinutesOutput? = nil,
                            liveSummary: LiveSummaryState? = nil) async throws -> DevTranslateLine {
        let plan = TranscriptTranslation.plan(transcript.utterances, target: target)
        var document = TranslationDocument(model: model, modelRevision: "", target: target, createdAt: Date(),
                                           sourceDigest: TranslationKey.digest(transcript.utterances),
                                           total: plan.count, complete: false, entries: [])
        _ = try await TranscriptTranslation.run(&document, utterances: transcript.utterances, plan: plan,
                                                translator: UtteranceTranslator(completer: completer)) { _ in .proceed }
        let entries = document.entries.map {
            Entry(index: $0.index, sourceLang: $0.sourceLanguage, targetLang: $0.targetLanguage, text: $0.text)
        }
        let done = Set(entries.map(\.index))
        let translator = UtteranceTranslator(completer: completer)
        var line = DevTranslateLine(target: target, model: model, utterances: transcript.utterances.count, entries: entries,
                                    skipped: transcript.utterances.indices.filter { !done.contains($0) })
        if let minutes {
            line.minutes = try await .make(SummaryTranslation.minutesTexts(minutes),
                                          context: SummaryTranslation.minutesContext(minutes), setting: target,
                                          translator: translator)
        }
        if let liveSummary {
            line.liveSummary = try await .make(SummaryTranslation.liveTexts(liveSummary),
                                               context: SummaryTranslation.liveContext(liveSummary), setting: target,
                                               translator: translator)
        }
        return line
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}
