import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct TimelineAlignerTests {
    @Test func contiguousChunkWithinToleranceIsAppended() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        let p = a.place(AudioFixtures.tone(start: 1.03, seconds: 1))
        #expect(p.silenceBefore == 0 && p.samples.count == 16_000)
        #expect(abs(a.writtenEnd.seconds - 2.0) < 1e-9)
    }
    @Test func alignerPadsGap() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        #expect(a.place(AudioFixtures.tone(start: 3, seconds: 1)).silenceBefore == 32_000)
    }
    @Test func overlapIsDroppedFromHead() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        #expect(a.place(AudioFixtures.tone(start: 0.8, seconds: 1)).samples.count == 12_800)
        #expect(a.place(AudioFixtures.tone(start: 0.0, seconds: 0.5)).samples.isEmpty)
    }
    @Test func chunkBeforeStartIsTrimmed() {
        var a = TimelineAligner(start: .init(seconds: 10))
        #expect(a.place(AudioFixtures.tone(start: 9.5, seconds: 1)).samples.count == 8_000)
    }
    @Test func paddingToEnd() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        #expect(a.padding(to: .init(seconds: 4)) == 48_000)
        #expect(a.padding(to: .init(seconds: 4)) == 0)
    }
    @Test func smallDriftIsCorrectedOnceWhenToleranceIsExceeded() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        #expect(a.place(AudioFixtures.tone(start: 1.04, seconds: 1)).silenceBefore == 0)
        // 2.08 is 0.08 s after the samples written so far (2.0 s): padded in one go.
        #expect(a.place(AudioFixtures.tone(start: 2.08, seconds: 1)).silenceBefore == 1_280)
        #expect(abs(a.writtenEnd.seconds - 3.08) < 1e-9)
    }
}
