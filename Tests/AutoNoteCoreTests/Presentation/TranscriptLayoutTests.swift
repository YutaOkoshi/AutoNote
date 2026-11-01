import Testing
import AutoNoteCore

@Suite struct TranscriptLayoutTests {
    @Test func legacyScrollerRoomIsAlwaysReserved() {
        // The same width whether the legacy scroller is showing or not: the scroller never rewraps a row.
        #expect(TranscriptLayout.rowWidth(outerWidth: 600, scrollerWidth: 15, legacyScroller: true) == 585)
    }

    @Test func overlayScrollerTakesNoRoom() {
        #expect(TranscriptLayout.rowWidth(outerWidth: 600, scrollerWidth: 15, legacyScroller: false) == 600)
    }

    @Test func unmeasuredWidthLeavesTheNaturalWidth() {
        #expect(TranscriptLayout.rowWidth(outerWidth: 0, scrollerWidth: 15, legacyScroller: true) == nil)
        #expect(TranscriptLayout.rowWidth(outerWidth: -1, scrollerWidth: 15, legacyScroller: false) == nil)
    }

    @Test func neverNegative() {
        #expect(TranscriptLayout.rowWidth(outerWidth: 10, scrollerWidth: 15, legacyScroller: true) == 0)
    }
}
