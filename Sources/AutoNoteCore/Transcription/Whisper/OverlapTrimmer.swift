import Foundation

/// Drops the tokens a hard-cut window shares with the previous one.
enum OverlapTrimmer {
    /// Joins the tokens starting at or after `droppingBefore` (seconds from the window start).
    static func text(_ tokens: [TimedToken], droppingBefore: Double) -> String {
        tokens.filter { $0.start >= droppingBefore }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
