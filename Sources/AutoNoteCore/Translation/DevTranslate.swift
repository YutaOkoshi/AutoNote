import Foundation

/// `autonote dev translate <transcript.json> [--target auto|ja|en] [--model <gguf>]`.
public struct DevTranslateArguments: Equatable, Sendable {
    public static let usage = "usage: autonote dev translate <transcript.json> [--target auto|ja|en] [--model <gguf>]"

    public struct Invalid: Error, Equatable {}

    public var transcript: URL
    public var target: TranslationTarget = .auto
    /// A real GGUF to translate with the on-device runtime; nil = the deterministic fake.
    public var model: URL?

    public static func parse(_ args: [String]) throws -> DevTranslateArguments {
        var transcript: URL?
        var target = TranslationTarget.auto
        var model: URL?
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
            case let a where a.hasPrefix("-"):
                throw Invalid()
            default:
                guard transcript == nil else { throw Invalid() }
                transcript = URL(filePath: args[i])
                i += 1
            }
        }
        guard let transcript else { throw Invalid() }
        return DevTranslateArguments(transcript: transcript, target: target, model: model)
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

    /// Translates `transcript` with `completer` (already loaded by the caller).
    public static func make(transcript: Transcript, target: TranslationTarget, model: String,
                            completer: any TextCompleting) async throws -> DevTranslateLine {
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
        return DevTranslateLine(target: target, model: model, utterances: transcript.utterances.count, entries: entries,
                                skipped: transcript.utterances.indices.filter { !done.contains($0) })
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}
