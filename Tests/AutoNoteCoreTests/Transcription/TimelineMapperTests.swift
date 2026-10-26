import AutoNoteCore
import Testing

@Suite struct TimelineMapperTests {
    @Test func mapperJumpsOverPause() {
        var m = TimelineMapper()
        m.append(chunk(silence(1), at: 0))
        m.append(chunk(silence(1), at: 10))          // 9 s pause
        #expect(m.timeline(atAudioSeconds: 0.5).seconds == 0.5)
        #expect(m.timeline(atAudioSeconds: 1.5).seconds == 10.5)
        #expect(m.audioSeconds == 2.0)
    }

    @Test func mapperIgnoresTinyJitter() {
        var m = TimelineMapper()
        m.append(chunk(silence(1), at: 0)); m.append(chunk(silence(1), at: 1.01))
        #expect(m.timeline(atAudioSeconds: 1.5).seconds == 1.5)
    }

    @Test func gapOfExactlyThresholdStartsNewSegment() {
        var m = TimelineMapper()
        m.append(chunk(silence(1), at: 0)); m.append(chunk(silence(1), at: 1.05))
        #expect(abs(m.timeline(atAudioSeconds: 1.5).seconds - 1.55) < 1e-9)
    }

    @Test func emptyMapperAndPastEndExtrapolate() {
        var m = TimelineMapper()
        #expect(m.timeline(atAudioSeconds: 2).seconds == 2)
        m.append(chunk(silence(1), at: 3))
        #expect(m.timeline(atAudioSeconds: 4).seconds == 7)
        #expect(m.timeline(atAudioSeconds: 0).seconds == 3)
    }
}
