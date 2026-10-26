import CoreMedia
import Foundation
@preconcurrency import Speech

/// Builds the `SpeechAnalyzer` module for one Apple engine and maps its results to `RecognizedSegment`s.
///
/// SDK names (Swift 6.3 / macOS 26 SDK, checked by compiling):
/// - Dictation: `DictationTranscriber.Preset.progressiveLongDictation`; `frequent` adds
///   `DictationTranscriber.ReportingOption.frequentFinalization` to that preset's reporting options.
/// - Speech: `SpeechTranscriber.Preset.progressiveTranscription`. `SpeechTranscriber.ReportingOption` has
///   `volatileResults`, `alternativeTranscriptions` and `fastResults` but no frequent finalization,
///   so `SpeechAdapter.supports(.frequentFinalization) == false`.
public protocol AppleSpeechModuleAdapter: Sendable {
    static var engineKind: EngineKind { get }
    static func supportedLocales() async -> [Locale]
    static func supports(_ s: SegmentationStrategy) -> Bool
    static func makeModule(locale: Locale, strategy: SegmentationStrategy)
        -> (module: any SpeechModule, results: AsyncThrowingStream<RecognizedSegment, Error>)
}

/// `DictationTranscriber`: works on Intel and Apple Silicon (availability is `supportedLocales`; it has no `isAvailable`).
public enum DictationAdapter: AppleSpeechModuleAdapter {
    public static var engineKind: EngineKind { .dictation }

    public static func supportedLocales() async -> [Locale] { await DictationTranscriber.supportedLocales }

    public static func supports(_ s: SegmentationStrategy) -> Bool { true }

    public static func makeModule(locale: Locale, strategy: SegmentationStrategy)
        -> (module: any SpeechModule, results: AsyncThrowingStream<RecognizedSegment, Error>) {
        let module = DictationTranscriber(locale: locale, preset: preset(for: strategy))
        return (module, segments(module.results) { RecognizedSegment($0.range, String($0.text.characters), $0.isFinal) })
    }

    static func preset(for strategy: SegmentationStrategy) -> DictationTranscriber.Preset {
        let base = DictationTranscriber.Preset.progressiveLongDictation
        guard strategy == .frequentFinalization else { return base }
        return DictationTranscriber.Preset(contentHints: base.contentHints, transcriptionOptions: base.transcriptionOptions,
                                           reportingOptions: base.reportingOptions.union([.frequentFinalization]),
                                           attributeOptions: base.attributeOptions)
    }
}

/// `SpeechTranscriber`: needs Apple Silicon (`isAvailable` is false and `supportedLocales` empty on Intel).
public enum SpeechAdapter: AppleSpeechModuleAdapter {
    public static var engineKind: EngineKind { .speech }

    public static func supportedLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales
    }

    public static func supports(_ s: SegmentationStrategy) -> Bool { s != .frequentFinalization }

    public static func makeModule(locale: Locale, strategy: SegmentationStrategy)
        -> (module: any SpeechModule, results: AsyncThrowingStream<RecognizedSegment, Error>) {
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return (module, segments(module.results) { RecognizedSegment($0.range, String($0.text.characters), $0.isFinal) })
    }
}

/// Forwards a module's results; cancelling the consumer cancels the forwarding.
private func segments<S: AsyncSequence & Sendable>(_ results: S, _ map: @escaping @Sendable (S.Element) -> RecognizedSegment)
    -> AsyncThrowingStream<RecognizedSegment, Error> where S.Element: Sendable {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await r in results { continuation.yield(map(r)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private extension RecognizedSegment {
    init(_ range: CMTimeRange, _ text: String, _ isFinal: Bool) {
        let start = range.start.seconds.isFinite ? range.start.seconds : 0
        let end = range.end.seconds.isFinite ? range.end.seconds : start
        self.init(audioStart: start, audioEnd: end, text: text, isFinal: isFinal)
    }
}
