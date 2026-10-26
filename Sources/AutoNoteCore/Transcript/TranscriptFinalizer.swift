import Foundation

/// Builds the raw (merged, de-echoed) and final (replaced, filler-free) transcripts (spec §6.4).
public struct TranscriptFinalizer: Sendable {
    private let replacer: Replacer
    private let fillerRemover: FillerRemover?
    private let deduplicator: EchoDeduplicator

    public init(dictionary: DictionaryFile, fillerRemoval: Bool, deduplicator: EchoDeduplicator = .init()) {
        self.replacer = Replacer(dictionary.replacements)
        self.fillerRemover = fillerRemoval ? FillerRemover(fillers: dictionary.fillers) : nil
        self.deduplicator = deduplicator
    }

    public func finalize(_ parts: [TrackTranscription], source: MeetingSource, engine: String,
                         language: Language) -> (raw: Transcript, final: Transcript) {
        let rawUtterances = deduplicator.deduplicate(TranscriptMerger.merge(parts, source: source))
        var finalUtterances = replacer.apply(rawUtterances)
        if let fillerRemover { finalUtterances = fillerRemover.clean(finalUtterances) }
        return (Transcript(utterances: rawUtterances, engine: engine, language: language),
                Transcript(utterances: finalUtterances, engine: engine, language: language))
    }
}
