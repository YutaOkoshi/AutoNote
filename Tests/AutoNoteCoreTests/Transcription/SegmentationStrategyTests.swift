import Testing
@testable import AutoNoteCore

@Suite struct SegmentationStrategyTests {
    @Test func strategyRawValuesMatchCLI() { #expect(SegmentationStrategy.allCases.map(\.rawValue) == ["default", "frequent", "silence"]) }
    @Test func dictationSupportsAllStrategies() { #expect(SegmentationStrategy.allCases.allSatisfy(DictationAdapter.supports)) }
    @Test func speechSupportsSilenceAndDefault() { #expect(SpeechAdapter.supports(.silenceFinalize) && SpeechAdapter.supports(.engineDefault)) }
    @Test func speechHasNoFrequentFinalization() { #expect(!SpeechAdapter.supports(.frequentFinalization)) }
    @Test func currentIsEngineDefault() { #expect(SegmentationStrategy.current == .engineDefault) }
    @Test func adaptersReportTheirEngine() { #expect(DictationAdapter.engineKind == .dictation && SpeechAdapter.engineKind == .speech) }
}
