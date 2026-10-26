import Foundation

/// Wall clock for the post-processing queue (`notBefore` is a wall-clock time).
public protocol QueueClock: Sendable {
    func now() -> Date
    /// Returns once `now() >= until`; throws `CancellationError` when the task is cancelled.
    func sleep(until: Date) async throws
}

public struct SystemQueueClock: QueueClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until: Date) async throws {
        let seconds = until.timeIntervalSinceNow
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
        try Task.checkCancellation()
    }
}
