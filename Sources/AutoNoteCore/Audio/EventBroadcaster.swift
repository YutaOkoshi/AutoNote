import Foundation
import Synchronization

/// Fans one sequence of values out to every current subscriber. Each `subscribe()` is a new stream that sees only
/// values yielded after it; a stream that is cancelled or dropped unregisters itself synchronously.
final class EventBroadcaster<Element: Sendable>: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    var count: Int { subscribers.withLock { $0.count } }

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }

    func yield(_ value: Element) {
        for continuation in subscribers.withLock({ Array($0.values) }) { continuation.yield(value) }
    }

    private func remove(_ id: UUID) {
        _ = subscribers.withLock { $0.removeValue(forKey: id) }
    }
}
