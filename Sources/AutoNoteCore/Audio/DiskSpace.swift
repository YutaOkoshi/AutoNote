import Foundation

/// Free space on the volume that holds the recordings.
public protocol DiskSpaceProvider: Sendable {
    func availableBytes(for url: URL) throws -> Int64
}

public enum DiskSpaceError: Error, Equatable, Sendable {
    case unavailable(path: String)
}

/// Asks the volume of `url` for its capacity available for important usage (falls back to plain available capacity).
public struct SystemDiskSpace: DiskSpaceProvider {
    public init() {}

    public func availableBytes(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        if let plain = values.volumeAvailableCapacity { return Int64(plain) }
        throw DiskSpaceError.unavailable(path: url.path)
    }
}
