import Foundation

public protocol CancellableTimer: Sendable {
    /// Idempotent. A cancelled timer never runs its action.
    func cancel()
}

/// Schedules delayed work so tests can drive time by hand (`ManualTimerScheduler`).
public protocol TimerScheduling: Sendable {
    func schedule(after seconds: Double, _ action: @Sendable @escaping () async -> Void) -> any CancellableTimer
}

extension TimerScheduling {
    public func sleep(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = schedule(after: seconds) { continuation.resume() }
        }
    }
}

/// Production scheduler backed by `Task.sleep`.
public struct TaskTimerScheduler: TimerScheduling {
    public init() {}

    public func schedule(after seconds: Double, _ action: @Sendable @escaping () async -> Void) -> any CancellableTimer {
        let task = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await action()
        }
        return TaskTimer(task: task)
    }

    private struct TaskTimer: CancellableTimer {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }
}
