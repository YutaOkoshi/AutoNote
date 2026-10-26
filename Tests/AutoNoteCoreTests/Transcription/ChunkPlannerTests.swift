@testable import AutoNoteCore
import AutoNoteTestSupport
import Testing

@Suite struct ChunkPlannerTests {
    @Test func speechThenSilenceCommitsAtBoundary() {
        var p = ChunkPlanner(); let a = p.ingest(tone(3.0) + silence(1.0))
        #expect(a.contains(.commit(from: 0, to: 3.0, nextFrom: 3.0)))
    }

    @Test func longSpeechHardCutsWithOverlap() {
        var p = ChunkPlanner(); #expect(p.ingest(tone(10)).contains(.commit(from: 0, to: 8, nextFrom: 7)))
    }

    @Test func partialEveryTwoSeconds() {
        var p = ChunkPlanner()
        var tos: [Double] = []
        for c in PCMAudio.chunks(tone(5), track: .mic, chunkSeconds: 0.1, start: TimelineTime(seconds: 0)) {
            for case let .partial(from: _, to: to) in p.ingest(c.samples) { tos.append(to) }
        }
        #expect(tos == [2, 4])
    }

    @Test func silenceOnlyNeverDecodes() {
        var p = ChunkPlanner(); #expect(p.ingest(silence(20)).allSatisfy { if case .skip = $0 { true } else { false } })
    }

    @Test func shortBlipIsSkipped() {
        var p = ChunkPlanner()
        #expect(p.ingest(tone(0.1) + silence(9)) == [.skip(from: 0, to: 8)])
    }

    @Test func leadingSilenceIsTrimmed() {
        var p = ChunkPlanner()
        #expect(p.ingest(silence(2) + tone(3) + silence(1)).contains(.commit(from: 2, to: 5, nextFrom: 5)))
    }

    @Test func flushCommitsRemainder() {
        var p = ChunkPlanner(); _ = p.ingest(tone(1.5)); #expect(p.flush() == [.commit(from: 0, to: 1.5, nextFrom: 1.5)])
    }

    @Test func overlapTokensDropped() {
        #expect(OverlapTrimmer.text([.init(start: 0.2, end: 0.8, text: "重なり"), .init(start: 1.3, end: 2.0, text: "続き")], droppingBefore: 1.0) == "続き")
    }
}
