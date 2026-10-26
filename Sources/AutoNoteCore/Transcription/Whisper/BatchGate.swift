import Foundation
import Synchronization

/// Pauses the batch transcription while a recording is running (要件書 §13). Plan 05's queue calls
/// `pause()` when recording starts and `resume()` when it ends. `isPaused` is a synchronous read so
/// whisper's abort check can poll it.
public actor BatchGate {
    private let paused = Mutex(false)
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public nonisolated var isPaused: Bool { paused.withLock { $0 } }

    public func pause() { paused.withLock { $0 = true } }

    public func resume() {
        paused.withLock { $0 = false }
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Returns at once when not paused; otherwise waits for `resume()`. Also returns promptly when the
    /// waiting task is cancelled (the caller checks cancellation afterwards; the gate stays paused).
    public func waitIfPaused() async {
        guard isPaused else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
