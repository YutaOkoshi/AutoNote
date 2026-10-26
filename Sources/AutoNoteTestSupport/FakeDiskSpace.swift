import Foundation
import AutoNoteCore

/// Free space the test sets by hand (default 100 GB).
public final class FakeDiskSpace: DiskSpaceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64

    public init(bytes: Int64 = 100_000_000_000) { _bytes = bytes }

    public var bytes: Int64 {
        get { lock.withLock { _bytes } }
        set { lock.withLock { _bytes = newValue } }
    }

    public func availableBytes(for url: URL) throws -> Int64 { bytes }
}
