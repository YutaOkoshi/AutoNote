import Testing
@testable import AutoNoteCore

private func t(_ s: Double) -> TimelineTime { TimelineTime(seconds: s) }

@Suite struct RecentPeakWindowTests {
    @Test func keepsTheLastSecond() {
        var w = RecentPeakWindow()
        w.observe(peakDBFS: -20, at: t(0.2))
        #expect(w.peak(at: t(0.5)) == -20)
        w.observe(peakDBFS: -50, at: t(1.5))
        #expect(w.peak(at: t(1.6)) == -50)          // 0.2 は窓の外
        #expect(w.peak(at: t(3.0)) == -.infinity)
    }

    @Test func maxWithinWindow() {
        var w = RecentPeakWindow()
        w.observe(peakDBFS: -30, at: t(0.1))
        w.observe(peakDBFS: -10, at: t(0.4))
        #expect(w.peak(at: t(0.5)) == -10)
    }

    @Test func emptyWindowIsMinusInfinity() {
        #expect(RecentPeakWindow().peak(at: t(0)) == -.infinity)
    }

    @Test func exactlyOneSecondAgoIsOutside() {
        var w = RecentPeakWindow()
        w.observe(peakDBFS: -20, at: t(1.0))
        #expect(w.peak(at: t(1.999)) == -20)
        #expect(w.peak(at: t(2.0)) == -.infinity)
    }

    @Test func futureEntriesAreIgnored() {
        var w = RecentPeakWindow()
        w.observe(peakDBFS: -20, at: t(2.0))
        #expect(w.peak(at: t(1.5)) == -.infinity)
    }
}
