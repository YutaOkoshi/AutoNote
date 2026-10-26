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
    /// Suspends for `seconds` on this scheduler's clock. Mirrors `Task.sleep`: if the calling task is cancelled
    /// (before or during the sleep) it throws `CancellationError` promptly and cancels the pending timer.
    public func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        let box = SleepBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard box.install(continuation) else { return }
                box.attach(schedule(after: seconds) { box.fire() })
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Exactly one of `fire` / `cancel` resumes the continuation; the `resumed` flag decides which.
private final class SleepBox: @unchecked Sendable {
    // All state guarded by `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timer: (any CancellableTimer)?
    private var cancelled = false
    private var resumed = false

    /// Returns false (after resuming with `CancellationError`) when cancellation already happened.
    func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        lock.lock()
        guard !cancelled else {
            resumed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(_ timer: any CancellableTimer) {
        lock.lock()
        guard !resumed else { lock.unlock(); timer.cancel(); return }
        self.timer = timer
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !resumed, let continuation else { lock.unlock(); return }
        resumed = true; self.continuation = nil; timer = nil
        lock.unlock()
        continuation.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        guard !resumed, let continuation else { lock.unlock(); return }
        resumed = true; self.continuation = nil
        let timer = self.timer; self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation.resume(throwing: CancellationError())
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
