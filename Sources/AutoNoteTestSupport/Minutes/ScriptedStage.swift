import Foundation
import Synchronization
import AutoNoteCore

/// A queue stage whose n-th call returns `results[n]` (success once they run out). Each call appends `name`
/// to `log`, reports `progress` if given, waits for one element of `release` if given
/// (throwing `CancellationError` if cancelled meanwhile), then runs `onRun`.
public struct ScriptedStage: QueueStage {
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func next() -> Int { value.withLock { n in defer { n += 1 }; return n } }
    }

    public let name: String
    private let log: CallLog
    private let results: [Result<Void, StageError>]
    private let progress: Double?
    private let onRun: (@Sendable (inout Job) -> Void)?
    private let release: AsyncStream<Void>?
    private let calls = Counter()

    public init(name: String, log: CallLog, results: [Result<Void, StageError>] = [], progress: Double? = nil,
                onRun: (@Sendable (inout Job) -> Void)? = nil, release: AsyncStream<Void>? = nil) {
        self.name = name; self.log = log; self.results = results; self.progress = progress
        self.onRun = onRun; self.release = release
    }

    public func run(_ job: inout Job, context: StageContext) async throws {
        let call = calls.next()
        await log.append(name)
        if let progress { context.reportProgress(progress) }
        if let release {
            for await _ in release { break }
            try Task.checkCancellation()
        }
        onRun?(&job)
        if call < results.count, case .failure(let error) = results[call] { throw error }
    }
}
