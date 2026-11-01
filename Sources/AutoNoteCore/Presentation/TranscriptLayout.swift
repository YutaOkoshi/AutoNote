import Foundation

/// The live transcript's row width. A legacy (space-taking) scroller narrows a scroll view's content by its own
/// width while it shows, and it shows only while the content overflows; when the rows wrap differently at the two
/// widths, the content can grow past the view's height with the scroller and fit again without it, and the window
/// lays itself out until AppKit throws (the 2026-10-30 12:03 crash). Reserving the scroller's room at all times
/// keeps the rows' width, and so their height, the same whether the scroller shows or not.
public enum TranscriptLayout {
    /// The scroll view's own width less the legacy scroller's width; the full width with overlay scrollers.
    /// nil before the scroll view is measured (the rows take their natural width); never negative.
    public static func rowWidth(outerWidth: Double, scrollerWidth: Double, legacyScroller: Bool) -> Double? {
        guard outerWidth > 0 else { return nil }
        return max(0, outerWidth - (legacyScroller ? scrollerWidth : 0))
    }
}
