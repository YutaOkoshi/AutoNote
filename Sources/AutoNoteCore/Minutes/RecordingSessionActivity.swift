import Foundation

/// `RecordingActivity` over plan 02's `RecordingSession` (overview §8b): `.started` → `true`, `.stopped` → `false`.
/// A paused recording and the grace period after `.microphoneDetached` stay `true`. Equal values are not repeated.
public struct RecordingSessionActivity: RecordingActivity {
    private let initial: @Sendable () async -> Bool
    private let events: @Sendable () async -> AsyncStream<RecordingEvent>

    public init(initial: @escaping @Sendable () async -> Bool,
                events: @escaping @Sendable () async -> AsyncStream<RecordingEvent>) {
        self.initial = initial
        self.events = events
    }

    public init(session: RecordingSession) {
        self.init(initial: { await session.state != .idle }, events: { await session.events() })
    }

    public func isRecordingUpdates() async -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let initial = self.initial
        let events = self.events
        let task = Task {
            // Subscribe before reading the state so no change between the two is lost.
            let updates = await events()
            var last = await initial()
            continuation.yield(last)
            for await event in updates {
                let value: Bool
                switch event {
                case .started: value = true
                case .stopped: value = false
                default: continue
                }
                guard value != last else { continue }
                last = value
                continuation.yield(value)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
