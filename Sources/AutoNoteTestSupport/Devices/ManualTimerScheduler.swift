import Foundation
import AutoNoteCore

/// Time moves only when a test calls `advance(by:)`.
public final class ManualTimerScheduler: TimerScheduling, @unchecked Sendable {
    private struct Entry {
        let id: Int
        let deadline: Double
        let action: @Sendable () async -> Void
    }

    // All state guarded by `lock`.
    private let lock = NSLock()
    private var current: Double = 0
    private var entries: [Entry] = []
    private var nextID = 0

    public init() {}

    public var now: Double { lock.withLock { current } }
    /// Scheduled timers that have neither run nor been cancelled.
    public var pendingCount: Int { lock.withLock { entries.count } }
    /// Every timer ever scheduled, including cancelled and fired ones.
    public var scheduledCount: Int { lock.withLock { nextID } }

    public func schedule(after seconds: Double, _ action: @Sendable @escaping () async -> Void) -> any CancellableTimer {
        let id = lock.withLock {
            let id = nextID; nextID += 1
            entries.append(Entry(id: id, deadline: current + seconds, action: action))
            return id
        }
        return Timer(scheduler: self, id: id)
    }

    /// Negative `seconds` count as 0.
    /// Runs every action due within `seconds`, in deadline order (ties in scheduling order), awaiting each one.
    /// Actions scheduled by a running action also run if they fall due before the target time.
    public func advance(by seconds: Double) async {
        let target = lock.withLock { current + max(0, seconds) }
        while let entry = popDue(by: target) { await entry.action() }
        lock.withLock { current = target }
    }

    private func popDue(by target: Double) -> Entry? {
        lock.withLock {
            guard let index = entries.indices
                .filter({ entries[$0].deadline <= target })
                .min(by: { (entries[$0].deadline, entries[$0].id) < (entries[$1].deadline, entries[$1].id) })
            else { return nil }
            let entry = entries.remove(at: index)
            current = entry.deadline
            return entry
        }
    }

    fileprivate func cancel(_ id: Int) {
        lock.withLock { entries.removeAll { $0.id == id } }
    }

    private struct Timer: CancellableTimer {
        let scheduler: ManualTimerScheduler
        let id: Int
        func cancel() { scheduler.cancel(id) }
    }
}
