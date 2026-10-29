import Testing
@testable import AutoNoteCore

@Suite struct SegmentationStrategyTests {
    @Test func strategyRawValuesMatchCLI() { #expect(SegmentationStrategy.allCases.map(\.rawValue) == ["default", "frequent", "silence"]) }
    @Test func dictationSupportsAllStrategies() { #expect(SegmentationStrategy.allCases.allSatisfy(DictationAdapter.supports)) }
    @Test func speechSupportsSilenceAndDefault() { #expect(SpeechAdapter.supports(.silenceFinalize) && SpeechAdapter.supports(.engineDefault)) }
    @Test func speechHasNoFrequentFinalization() { #expect(!SpeechAdapter.supports(.frequentFinalization)) }
    /// On tools/samples/ja-segments.wav (Intel, DictationTranscriber) default and frequent
    /// both lumped the audio into two 60 s finals; silence split it into 10 finals, longest 8.98 s.
    @Test func chosenSegmentation() { #expect(SegmentationStrategy.current == .silenceFinalize) }
    @Test func adaptersReportTheirEngine() { #expect(DictationAdapter.engineKind == .dictation && SpeechAdapter.engineKind == .speech) }
}
