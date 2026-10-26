import Foundation
import AutoNoteCore

public actor InMemoryRegistryStorage: DeviceRegistryStorage {
    public struct Failure: Error, Equatable, Sendable { public init() {} }

    public private(set) var data: Data?
    public private(set) var backups: [Data] = []
    public private(set) var saveCount = 0
    public var failLoad = false
    public var failSave = false
    public var failBackup = false
    /// While true, `load()` parks until `releaseLoads()` (tests interleave a reload with other calls).
    private var holdingLoads = false
    private var parkedLoads: [CheckedContinuation<Void, Never>] = []
    /// Loads currently parked by `holdLoads()`.
    public var parkedLoadCount: Int { parkedLoads.count }

    public init(initial: Data? = nil) { data = initial }

    public func setFailures(load: Bool = false, save: Bool = false, backup: Bool = false) {
        failLoad = load; failSave = save; failBackup = backup
    }

    public func holdLoads() { holdingLoads = true }

    public func releaseLoads() {
        holdingLoads = false
        let parked = parkedLoads
        parkedLoads = []
        for continuation in parked { continuation.resume() }
    }

    public func load() async throws -> Data? {
        if holdingLoads { await withCheckedContinuation { parkedLoads.append($0) } }
        if failLoad { throw Failure() }
        return data
    }

    public func save(_ data: Data) async throws {
        if failSave { throw Failure() }
        saveCount += 1
        self.data = data
    }

    public func backupCorrupt(_ data: Data) async throws {
        if failBackup { throw Failure() }
        backups.append(data)
    }
}
