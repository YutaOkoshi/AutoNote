import Foundation
import AutoNoteCore

/// Free space the test sets by hand (default 100 GB). Counts reads; throws `error` instead when it is set.
public final class FakeDiskSpace: DiskSpaceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64
    private var _error: (any Error)?
    private var _calls = 0

    public init(bytes: Int64 = 100_000_000_000) { _bytes = bytes }

    public var bytes: Int64 {
        get { lock.withLock { _bytes } }
        set { lock.withLock { _bytes = newValue } }
    }

    public var error: (any Error)? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    /// Number of `availableBytes(for:)` calls so far, including those that threw.
    public var calls: Int { lock.withLock { _calls } }

    public func availableBytes(for url: URL) throws -> Int64 {
        try lock.withLock {
            _calls += 1
            if let _error { throw _error }
            return _bytes
        }
    }
}
