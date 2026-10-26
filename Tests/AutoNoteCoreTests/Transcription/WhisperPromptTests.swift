import Testing
@testable import AutoNoteCore

@Suite struct WhisperPromptTests {
    @Test func joinsHintsWithIdeographicComma() {
        #expect(WhisperPrompt.make(hints: ["所沢", "Kubernetes"]) == "所沢、Kubernetes")
    }

    @Test func emptyHintsGiveNil() {
        #expect(WhisperPrompt.make(hints: []) == nil)
    }

    @Test func longDictionaryIsTrimmed() {
        let terms = (0..<500).map { "用語\($0)" }
        let prompt = WhisperPrompt.make(hints: terms)
        #expect(prompt == HintBudget.fit(terms, separator: "、").included.joined(separator: "、"))
        #expect(prompt != terms.joined(separator: "、"))
    }
}
