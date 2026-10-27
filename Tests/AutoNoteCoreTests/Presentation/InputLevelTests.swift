import Testing
@testable import AutoNoteCore

@Suite struct InputLevelTests {
    @Test(arguments: [(-70.0, 0), (-60.0, 1), (-48.0, 2), (-36.0, 3), (-24.0, 4), (-12.0, 5), (0.0, 5), (-Double.infinity, 0)])
    func bars(db: Double, bars: Int) {
        #expect(InputLevelTracker.bars(peakDBFS: db) == bars)
    }

    @Test func louderTrackWins() {
        var tracker = InputLevelTracker()
        let level = tracker.observe([TrackLevel(track: .mic, peakDBFS: -70), TrackLevel(track: .system, peakDBFS: -20)],
                                    recording: true)
        #expect(level == InputLevel(bars: 4, quiet: false))
    }

    @Test func quietAfterTenSilentTicks() {
        var tracker = InputLevelTracker()
        let silent = [TrackLevel(track: .mic, peakDBFS: -70)]
        for _ in 1..<InputLevelTracker.quietTicks {
            #expect(tracker.observe(silent, recording: true).quiet == false)
        }
        #expect(tracker.observe(silent, recording: true) == InputLevel(bars: 0, quiet: true))
        #expect(tracker.observe([TrackLevel(track: .mic, peakDBFS: -30)], recording: true) == InputLevel(bars: 3, quiet: false))
    }

    @Test func pausedTicksDoNotCount() {
        var tracker = InputLevelTracker()
        let silent = [TrackLevel(track: .mic, peakDBFS: -70)]
        for _ in 0..<InputLevelTracker.quietTicks { _ = tracker.observe(silent, recording: true) }
        #expect(tracker.observe(silent, recording: false).quiet == false)
        for _ in 1..<InputLevelTracker.quietTicks {
            #expect(tracker.observe(silent, recording: true).quiet == false)
        }
        #expect(tracker.observe(silent, recording: true).quiet == true)
    }

    @Test func noLevelsMeansNoBars() {
        var tracker = InputLevelTracker()
        #expect(tracker.observe([], recording: false) == InputLevel(bars: 0, quiet: false))
    }
}
