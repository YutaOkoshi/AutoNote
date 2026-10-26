import AutoNoteCore
import Foundation
import Synchronization

/// In-memory `ModelDownloading`: writes `payload` (or only `failAfterBytes` of it, then throws).
public final class FakeModelDownloader: ModelDownloading, @unchecked Sendable {
    public struct Interrupted: Error, Equatable {}

    private let payload: Data
    private let failAfterBytes: Int?
    private let delay: Duration
    private let calls = Mutex(0)

    public init(payload: Data, failAfterBytes: Int? = nil, delay: Duration = .zero) {
        self.payload = payload
        self.failAfterBytes = failAfterBytes
        self.delay = delay
    }

    public var callCount: Int { calls.withLock { $0 } }

    public func download(
        _ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        calls.withLock { $0 += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        let total = Int64(payload.count)
        if let limit = failAfterBytes, limit < payload.count {
            try payload.prefix(limit).write(to: destination)
            progress(Int64(limit), total)
            throw Interrupted()
        }
        progress(total / 2, total)
        try payload.write(to: destination)
        progress(total, total)
    }
}
