import Foundation

/// Whether a recording is in progress. The stream yields the current value right after subscribing,
/// then every change. What the queue does with it is Task 8's concern.
public protocol RecordingActivity: Sendable {
    func isRecordingUpdates() async -> AsyncStream<Bool>
}

/// Always `false` (used by `dev summarize`).
public struct NeverRecording: RecordingActivity {
    public init() {}

    public func isRecordingUpdates() async -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(false)
            continuation.finish()
        }
    }
}
