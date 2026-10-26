import AutoNoteCore
import Testing

@Suite struct SilenceDetectorTests {
    @Test func silenceDetectorFindsBoundary() {
        var d = SilenceDetector()
        let b = d.process(tone(1) + silence(1) + tone(1))
        #expect(b.count == 1)
        #expect(abs(b[0] - 1.0) < 0.021)
    }

    @Test func silenceOnlyHasNoBoundary() {
        var d = SilenceDetector()
        #expect(d.process(silence(5)).isEmpty)
    }

    @Test func boundaryAcrossCalls() {
        var d = SilenceDetector()
        var all: [Double] = []
        let audio = tone(1) + silence(1)
        let step = 1_600
        for i in stride(from: 0, to: audio.count, by: step) {
            all += d.process(Array(audio[i..<min(i + step, audio.count)]))
        }
        #expect(all.count == 1)
        #expect(abs(all[0] - 1.0) < 0.021)
    }

    @Test func shortSpeechIsNotAnUtterance() {
        var d = SilenceDetector()
        #expect(d.process(tone(0.2) + silence(2)).isEmpty)
    }

    @Test func secondUtteranceGivesSecondBoundary() {
        var d = SilenceDetector()
        let b = d.process(tone(1) + silence(1) + tone(1) + silence(1))
        #expect(b.count == 2)
        #expect(abs(b[1] - 3.0) < 0.021)
    }
}
