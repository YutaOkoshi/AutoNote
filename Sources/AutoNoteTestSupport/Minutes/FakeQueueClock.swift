import Foundation
import AutoNoteCore

/// Manual wall clock for the queue. `sleep(until:)` returns once `advance(by:)` reaches the deadline.
public final class FakeQueueClock: QueueClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var waiters: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = [:]

    public init(now: Date = Samples.start) { current = now }

    public func now() -> Date { lock.withLock { current } }

    public func advance(by seconds: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            current = current.addingTimeInterval(seconds)
            let due = waiters.filter { $0.value.deadline <= current }
            for id in due.keys { waiters[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }

    public func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, now, cancelled }
                let outcome = lock.withLock { () -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if current >= deadline { return .now }
                    waiters[id] = (deadline, continuation)
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .now: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}
