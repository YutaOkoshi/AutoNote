import Foundation
import AutoNoteCore

public final class FakeSleepWake: SleepWakeObserving, @unchecked Sendable {
    // All state guarded by `lock`.
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PowerEvent>.Continuation] = [:]

    public init() {}

    public func events() -> AsyncStream<PowerEvent> {
        let (stream, continuation) = AsyncStream<PowerEvent>.makeStream()
        let id = UUID()
        lock.withLock { continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.continuations[id] = nil }
        }
        return stream
    }

    /// Delivers `event` to every live subscriber, in call order.
    public func send(_ event: PowerEvent) {
        let live = lock.withLock { Array(continuations.values) }
        live.forEach { $0.yield(event) }
    }
}
