import Foundation
import Synchronization
import AutoNoteCore

/// A `RecordingActivity` driven by `set(_:)`. Every subscriber gets the current value first, then each `set`.
public final class FakeRecordingActivity: RecordingActivity, @unchecked Sendable {
    private struct State {
        var current = false
        var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init(_ recording: Bool = false) {
        state.withLock { $0.current = recording }
    }

    public func set(_ recording: Bool) {
        state.withLock { s in
            s.current = recording
            for continuation in s.continuations.values { continuation.yield(recording) }
        }
    }

    public func isRecordingUpdates() async -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        state.withLock { s in
            s.continuations[id] = continuation
            continuation.yield(s.current)
        }
        return stream
    }
}
