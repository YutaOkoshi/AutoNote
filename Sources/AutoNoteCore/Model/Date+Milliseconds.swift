import Foundation

extension Date {
    /// Manifest dates are stored at millisecond precision (`AutoNoteJSON`); truncating before saving makes the
    /// in-memory value equal to what is read back.
    var truncatedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}
