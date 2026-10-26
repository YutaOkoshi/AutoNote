import Foundation
import AutoNoteCore

public actor InMemoryRegistryStorage: DeviceRegistryStorage {
    public private(set) var data: Data?
    public private(set) var backups: [Data] = []

    public init(initial: Data? = nil) { data = initial }

    public func load() async throws -> Data? { data }
    public func save(_ data: Data) async throws { self.data = data }
    public func backupCorrupt(_ data: Data) async throws { backups.append(data) }
}
