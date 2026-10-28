import AutoNoteCore
import Testing

private let small = BatchWindowPlanner.Config(nominal: 20, lookback: 6, overlap: 5, tailMerge: 4)

private func plan(_ pcm: [Int16], _ c: BatchWindowPlanner.Config) -> [BatchWindow] {
    BatchWindowPlanner(config: c).plan(sampleCount: pcm.count) { Array(pcm[$0]) }
}

private func s(_ seconds: Double) -> Int { Int(seconds * 16_000) }

@Suite struct BatchWindowPlannerTests {
    @Test func defaultsAreTheSpecValues() {
        #expect(BatchWindowPlanner.Config() == .init(nominal: 600, lookback: 60, overlap: 5, tailMerge: 120))
    }

    @Test func defaultsAndTheTestConfigPassThePreconditions() {
        _ = BatchWindowPlanner()
        _ = BatchWindowPlanner(config: small)
        _ = BatchWindowPlanner(config: .init(nominal: 20, lookback: 0, overlap: 0, tailMerge: 0))
    }

    @Test func invalidConfigTraps() async {
        // nominal ≤ 0 や負の overlap は plan が進まず無限ループ、負の lookback は Range で trap する
        await #expect(processExitsWith: .failure) { _ = BatchWindowPlanner(config: .init(nominal: 0, lookback: 0, overlap: 0, tailMerge: 0)) }
        await #expect(processExitsWith: .failure) { _ = BatchWindowPlanner(config: .init(nominal: 20, lookback: 6, overlap: -1, tailMerge: 4)) }
        await #expect(processExitsWith: .failure) { _ = BatchWindowPlanner(config: .init(nominal: 20, lookback: -1, overlap: 5, tailMerge: 4)) }
        await #expect(processExitsWith: .failure) { _ = BatchWindowPlanner(config: .init(nominal: 20, lookback: 6, overlap: 5, tailMerge: -1)) }
    }

    @Test func shortFileIsOneWindow() {
        #expect(plan(tone(18), small) == [BatchWindow(index: 0, read: 0..<s(18), owned: 0..<s(18), isLast: true)])
        #expect(plan(tone(24), small).count == 1)
        #expect(plan([], small) == [BatchWindow(index: 0, read: 0..<0, owned: 0..<0, isLast: true)])
    }

    @Test func cutsAtTheMiddleOfSilence() {
        #expect(plan(tone(16) + silence(2) + tone(22), small) == [
            BatchWindow(index: 0, read: 0..<s(17), owned: 0..<s(17), isLast: false),
            BatchWindow(index: 1, read: s(17)..<s(40), owned: s(17)..<s(40), isLast: true),
        ])
    }

    @Test func longestSilenceInTheLookbackWins() {
        let w = plan(tone(15) + silence(1) + tone(1) + silence(2) + tone(19), small)
        #expect(w.first?.owned.upperBound == s(18))
    }

    @Test func silenceShorterThanMinimumIsAHardCut() {
        #expect(plan(tone(17) + silence(0.5) + tone(22.5), small) == [
            BatchWindow(index: 0, read: 0..<s(25), owned: 0..<s(20), isLast: false),
            BatchWindow(index: 1, read: s(15)..<s(40), owned: s(20)..<s(40), isLast: true),
        ])
    }

    @Test func remainderOverTheTailMergeMakesAThirdWindow() {
        #expect(plan(tone(45), small).map(\.read) == [0..<s(25), s(15)..<s(45), s(35)..<s(45)])
        #expect(plan(tone(45), small).map(\.owned) == [0..<s(20), s(20)..<s(40), s(40)..<s(45)])
        #expect(plan(tone(43), small).count == 2)
    }

    @Test func ownershipAtTheCutGoesToTheLaterWindow() {
        let w = plan(tone(40), small)
        #expect(w[0].owns(midpointSeconds: 19.99) && !w[0].owns(midpointSeconds: 20))
        #expect(w[1].owns(midpointSeconds: 20) && !w[1].owns(midpointSeconds: 19.99))
        #expect(w[1].owns(midpointSeconds: 1_000))
    }

    @Test func softCutOwnsEverySegmentOnBothSides() {
        // 17 秒の無音の切れ目は重ならないので、窓 1 は切れ目を越えた中点も採り、窓 2 は切れ目より前の中点も採る
        let w = plan(tone(16) + silence(2) + tone(22), small)
        #expect(w[0].owns(midpointSeconds: 17.5))
        #expect(w[1].owns(midpointSeconds: 16.5))
    }

    @Test func softCutAfterAHardCutKeepsOnlyTheHardLowerBound() {
        // 20 秒は硬い切れ目、窓 2 の後ろ 35 秒付近で無音の切れ目
        let w = plan(tone(34) + silence(2) + tone(20), small)
        #expect(w.count == 3)
        #expect(w[1].read.lowerBound < w[1].owned.lowerBound && w[1].read.upperBound == w[1].owned.upperBound)
        #expect(!w[1].owns(midpointSeconds: 19.99) && w[1].owns(midpointSeconds: 20))
        #expect(w[1].owns(midpointSeconds: 36))
    }
}
