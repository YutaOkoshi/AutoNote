import Foundation

/// Thrown by a queue stage; the queue decides what to do with it.
public enum StageError: Error, Equatable, Sendable {
    case retry(after: TimeInterval, reason: String)
    case failed(reason: String)
    case awaitingConfirmation(path: String)
}

public enum SummaryFailureKind: String, Codable, Sendable {
    case notLoggedIn = "not_logged_in"
    case rateLimited = "rate_limited"
    case contextExceeded = "context_exceeded"
    case timedOut = "timed_out"
    case claudeNotFound = "claude_not_found"
    case invalidOutput = "invalid_output"
    case other

    /// `"<raw>: <message>"`, stored in `Job.summaryFailure`.
    public static func encode(_ kind: Self, message: String) -> String { "\(kind.rawValue): \(message)" }

    /// Reads the leading raw value; unknown prefixes map to `.other`, nil stays nil.
    public static func of(_ summaryFailure: String?) -> Self? {
        guard let s = summaryFailure else { return nil }
        let head = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        return Self(rawValue: head) ?? .other
    }
}
