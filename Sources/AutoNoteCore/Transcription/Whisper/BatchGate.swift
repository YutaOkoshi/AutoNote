import Synchronization

/// Pauses the batch transcription while a recording is running (要件書 §13). Plan 05's queue calls
/// `pause()` when recording starts and `resume()` when it ends. `isPaused` is a synchronous read so
/// whisper's abort check can poll it.
public actor BatchGate {
    private let paused = Mutex(false)
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public nonisolated var isPaused: Bool { paused.withLock { $0 } }

    public func pause() { paused.withLock { $0 = true } }

    public func resume() {
        paused.withLock { $0 = false }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// Returns at once when not paused; otherwise waits for `resume()`.
    public func waitIfPaused() async {
        guard isPaused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
