import AutoNoteCore
import Testing

@Suite struct LanguageRunPlannerTests {
    private let planner = LanguageRunPlanner()
    private func s(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }
    private let ja = LanguageGuess(ja: 0.95, en: 0.03)
    private let en = LanguageGuess(ja: 0.02, en: 0.96)

    // MARK: blocks

    @Test func blockEndsInTheMiddleOfTheFirstSilenceAfterEnoughSpeech() {
        // 8 秒の発話の後の無音（8 秒から）で切る。切れ目は無音の始まり + minSilence / 2。2 つ目も 8 秒で 17 秒の無音で切る
        let blocks = planner.blocks(tone(8) + silence(1) + tone(8) + silence(1) + tone(8))
        #expect(blocks == [0..<s(8.25), s(8.25)..<s(17.25), s(17.25)..<s(26)])
    }

    @Test func silenceBeforeEnoughSpeechDoesNotCut() {
        // 4 秒では 6 秒に足りないので最初の無音では切らない
        let blocks = planner.blocks(tone(4) + silence(1) + tone(4) + silence(1) + tone(8))
        #expect(blocks == [0..<s(9.25), s(9.25)..<s(18)])
    }

    @Test func pauseShorterThanMinSilenceDoesNotCut() {
        #expect(planner.blocks(tone(8) + silence(0.3) + tone(8)).count == 1)
    }

    @Test func shortTailJoinsTheBlockBeforeIt() {
        #expect(planner.blocks(tone(8) + silence(1) + tone(3)) == [0..<s(12)])
        #expect(planner.blocks(tone(8) + silence(10)) == [0..<s(18)])
    }

    @Test func blocksCoverTheWholeWindowInOrder() {
        let pcm = silence(2) + tone(7) + silence(0.6) + tone(2) + silence(3) + tone(9) + silence(1) + tone(6.5) + silence(0.7)
        let blocks = planner.blocks(pcm)
        #expect(blocks.first?.lowerBound == 0)
        #expect(blocks.last?.upperBound == pcm.count)
        #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func noSpeechIsOneBlockAndEmptyIsNone() {
        #expect(planner.blocks(silence(30)) == [0..<s(30)])
        #expect(planner.blocks([]).isEmpty)
    }

    @Test func onlyBlocksWithSpeechAreJudged() {
        let pcm = silence(10) + tone(3)
        #expect(!planner.shouldJudge(pcm, 0..<s(10)))
        #expect(!planner.shouldJudge(pcm, 0..<s(11.5)))   // 発話 1.5 秒 < 2 秒
        #expect(planner.shouldJudge(pcm, 0..<s(13)))
    }

    // MARK: runs

    private let b = [0..<10, 10..<20, 20..<30, 30..<40]

    @Test func sameLanguageBlocksMergeIntoOneRun() {
        #expect(planner.runs(b, guesses: [ja, ja, ja, ja]) == [.init(samples: 0..<40, language: .ja)])
        #expect(planner.runs(b, guesses: [en, en, en, en]) == [.init(samples: 0..<40, language: .en)])
    }

    @Test func aDecisiveGuessSwitchesTheLanguage() {
        #expect(planner.runs(b, guesses: [en, en, ja, ja]) == [
            .init(samples: 0..<20, language: .en), .init(samples: 20..<40, language: .ja),
        ])
    }

    @Test func aWeakGuessKeepsThePreviousLanguage() {
        let weakEn = LanguageGuess(ja: 0.35, en: 0.55)   // en の割合 0.61 < 0.8
        #expect(planner.runs(b, guesses: [ja, weakEn, ja, ja]) == [.init(samples: 0..<40, language: .ja)])
    }

    @Test func unjudgedBlocksKeepThePreviousLanguage() {
        #expect(planner.runs(b, guesses: [en, nil, nil, ja]) == [
            .init(samples: 0..<30, language: .en), .init(samples: 30..<40, language: .ja),
        ])
    }

    @Test func theFirstLanguageIsTheFirstDecisiveGuess() {
        let weakEn = LanguageGuess(ja: 0.3, en: 0.6)
        #expect(planner.runs(b, guesses: [nil, weakEn, ja, ja]) == [.init(samples: 0..<40, language: .ja)])
        #expect(planner.runs(b, guesses: [nil, weakEn, nil, nil]) == [.init(samples: 0..<40, language: .en)])
        #expect(planner.runs(b, guesses: [nil, nil, nil, nil]) == [.init(samples: 0..<40, language: .ja)])
    }
}
