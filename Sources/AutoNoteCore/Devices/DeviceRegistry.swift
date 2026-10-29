import Foundation
import CryptoKit

public enum DeviceDisposition: String, Codable, Sendable {
    case registered, ignored
}

public struct RegisteredDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var transport: DeviceTransport
    public var deviceUID: String
    public var modelUID: String?
    public var uidKind: UIDKind
    public var disposition: DeviceDisposition
    public var startOnModelMatch: Bool
    public var registeredOn: MacIdentity
    public var registeredAt: Date

    // Raw values are the camelCase form AutoNoteJSON's decoder produces from "device_uid" (see DeviceIdentity).
    enum CodingKeys: String, CodingKey {
        case id, name, transport
        case deviceUID = "deviceUid"
        case modelUID = "modelUid"
        case uidKind, disposition, startOnModelMatch, registeredOn, registeredAt
    }

    public init(id: String, name: String, transport: DeviceTransport, deviceUID: String, modelUID: String?,
                uidKind: UIDKind, disposition: DeviceDisposition, startOnModelMatch: Bool,
                registeredOn: MacIdentity, registeredAt: Date) {
        self.id = id; self.name = name; self.transport = transport; self.deviceUID = deviceUID
        self.modelUID = modelUID; self.uidKind = uidKind; self.disposition = disposition
        self.startOnModelMatch = startOnModelMatch; self.registeredOn = registeredOn; self.registeredAt = registeredAt
    }
}

public enum MatchRule: String, Sendable {
    case deviceUID, modelUIDAndName, name
}

public enum RegistryMatch: Equatable, Sendable {
    case registered(entryID: String, rule: MatchRule)
    case ignored(entryID: String)
    case reRegistrationSuggested(entryID: String)
    case unknown
}

public enum DeviceRegistryError: Error, Equatable {
    case unknownEntry(String)
    /// The stored file could not be read or set aside; the registry is read-only until a reload succeeds.
    case storageUnavailable(String)
}

public protocol DeviceRegistryStorage: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
    func backupCorrupt(_ data: Data) async throws
}

/// `{"version": 1, "devices": [...]}`.
struct DeviceRegistryFile: Codable, Equatable {
    var version: Int
    var devices: [RegisteredDevice]
}

/// Mutations (`reload`, `register`, `ignore`, `remove`, `setDisposition`, `setStartOnModelMatch`) run one at a time
/// through a FIFO gate (`OperationGate`), so one caller's read-modify-save never interleaves with
/// another's across the storage `await` (Y25). `entries()` and `match` read the last committed state and never see
/// a half-finished reload.
public actor DeviceRegistry {
    private let storage: any DeviceRegistryStorage
    private let mac: any MacIdentityProviding
    private let now: @Sendable () -> Date
    private var items: [RegisteredDevice] = []
    private var loadFailed: Error?
    private var gate = OperationGate()
    /// Mutations parked at the gate (tests use it to know a call is queued).
    private(set) var queuedOperations = 0

    public init(storage: any DeviceRegistryStorage, mac: any MacIdentityProviding,
                now: @Sendable @escaping () -> Date = Date.init) {
        self.storage = storage; self.mac = mac; self.now = now
    }

    /// A missing file, a legacy top-level array, or an undecodable file all leave a usable registry
    /// (undecodable content is first handed to `backupCorrupt`). An I/O error from `load` or `backupCorrupt`
    /// leaves it empty and read-only (`loadFailed`) so the only copy is never overwritten; a later successful
    /// reload clears that.
    /// The new state is built in locals and assigned once after the last `await`, so readers see the old
    /// registry or the new one, never an empty interim.
    public func reload() async {
        await serialized {
            let (next, failure) = await loadState()
            items = next
            loadFailed = failure
        }
    }

    private func loadState() async -> ([RegisteredDevice], (any Error)?) {
        let data: Data?
        do { data = try await storage.load() } catch { return ([], error) }
        guard let data else { return ([], nil) }
        if let file = try? AutoNoteJSON.decoder().decode(DeviceRegistryFile.self, from: data) {
            return (file.devices, nil)
        }
        if let legacy = try? AutoNoteJSON.decoder().decode([RegisteredDevice].self, from: data) {
            return (legacy, nil)
        }
        do { try await storage.backupCorrupt(data) } catch { return ([], error) }
        return ([], nil)
    }

    public func entries() -> [RegisteredDevice] { items }

    public func match(_ device: DeviceIdentity) -> RegistryMatch {
        if loadFailed != nil { return .unknown }
        if let hit = items.first(where: { $0.deviceUID == device.deviceUID }) {
            return hit.disposition == .registered
                ? .registered(entryID: hit.id, rule: .deviceUID) : .ignored(entryID: hit.id)
        }
        let thisMac = mac.current()
        func resolve(_ hit: RegisteredDevice, _ rule: MatchRule) -> RegistryMatch {
            guard hit.registeredOn.id == thisMac.id else { return .reRegistrationSuggested(entryID: hit.id) }
            return hit.startOnModelMatch ? .registered(entryID: hit.id, rule: rule) : .unknown
        }
        switch device.transport {
        case .usb:
            if let model = device.modelUID, model != "0 0",
               let hit = preferred(items.filter {
                   $0.disposition == .registered && $0.transport == .usb && $0.modelUID == model && $0.name == device.name
               }, mac: thisMac) {
                return resolve(hit, .modelUIDAndName)
            }
        case .bluetooth:
            if let hit = preferred(items.filter {
                $0.disposition == .registered && $0.transport == .bluetooth && $0.name == device.name
            }, mac: thisMac) {
                return resolve(hit, .name)
            }
        default:
            break
        }
        return .unknown
    }

    @discardableResult
    public func register(_ device: DeviceIdentity, startOnModelMatchDefault: Bool = false) async throws -> RegisteredDevice {
        try await serialized {
            try requireWritable()
            if let index = items.firstIndex(where: { $0.deviceUID == device.deviceUID }) {
                var entry = items[index]
                entry.disposition = .registered
                entry.name = device.name; entry.modelUID = device.modelUID
                entry.uidKind = device.uidKind; entry.transport = device.transport
                return try await commit(entry, at: index)
            }
            return try await append(device, disposition: .registered,
                                    startOnModelMatch: startOnModelMatchDefault || device.uidKind == .portBased)
        }
    }

    public func ignore(_ device: DeviceIdentity) async throws {
        try await serialized {
            try requireWritable()
            if let index = items.firstIndex(where: { $0.deviceUID == device.deviceUID }) {
                var entry = items[index]
                entry.disposition = .ignored
                try await commit(entry, at: index)
            } else {
                try await append(device, disposition: .ignored, startOnModelMatch: false)
            }
        }
    }

    public func remove(entryID: String) async throws {
        try await serialized {
            try requireWritable()
            guard let index = items.firstIndex(where: { $0.id == entryID }) else {
                throw DeviceRegistryError.unknownEntry(entryID)
            }
            var next = items
            next.remove(at: index)
            try await persist(next)
            items = next
        }
    }

    public func setDisposition(entryID: String, _ d: DeviceDisposition) async throws {
        try await serialized {
            try requireWritable()
            let index = try indexOf(entryID)
            var entry = items[index]
            entry.disposition = d
            try await commit(entry, at: index)
        }
    }

    public func setStartOnModelMatch(entryID: String, _ on: Bool) async throws {
        try await serialized {
            try requireWritable()
            let index = try indexOf(entryID)
            var entry = items[index]
            entry.startOnModelMatch = on
            try await commit(entry, at: index)
        }
    }

    // MARK: - Helpers

    /// FIFO admission for mutations. Never call it from inside `body`: that would deadlock.
    private func serialized<T>(_ body: () async throws -> T) async rethrows -> T {
        if !gate.tryEnter() {
            queuedOperations += 1
            await withCheckedContinuation { gate.wait($0) }
            queuedOperations -= 1
        }
        defer { gate.leave() }
        return try await body()
    }

    /// An entry made on this Mac wins over another Mac's.
    private func preferred(_ hits: [RegisteredDevice], mac: MacIdentity) -> RegisteredDevice? {
        hits.first(where: { $0.registeredOn.id == mac.id }) ?? hits.first
    }

    private func requireWritable() throws {
        if let loadFailed { throw DeviceRegistryError.storageUnavailable(String(describing: loadFailed)) }
    }

    private func indexOf(_ id: String) throws -> Int {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw DeviceRegistryError.unknownEntry(id) }
        return index
    }

    /// Saves first, so a failed save leaves the in-memory registry as it was.
    @discardableResult
    private func commit(_ entry: RegisteredDevice, at index: Int) async throws -> RegisteredDevice {
        var next = items
        next[index] = entry
        try await persist(next)
        items = next
        return entry
    }

    @discardableResult
    private func append(_ device: DeviceIdentity, disposition: DeviceDisposition, startOnModelMatch: Bool) async throws -> RegisteredDevice {
        let entry = RegisteredDevice(
            id: UUID().uuidString.lowercased(), name: device.name, transport: device.transport,
            deviceUID: device.deviceUID, modelUID: device.modelUID, uidKind: device.uidKind,
            disposition: disposition, startOnModelMatch: startOnModelMatch,
            registeredOn: mac.current(), registeredAt: now().truncatedToMilliseconds)
        let next = items + [entry]
        try await persist(next)
        items = next
        return entry
    }

    private func persist(_ devices: [RegisteredDevice]) async throws {
        var data = try AutoNoteJSON.encoder().encode(DeviceRegistryFile(version: 1, devices: devices))
        data.append(0x0A)
        try await storage.save(data)
    }
}

/// Production storage: `devices.json` through `PortableConfigStore` (Vault copy plus app-side mirror).
/// Unreadable content is set aside once per distinct content as `<app area>/devices.json.corrupt-<yyyyMMdd-HHmmss>`.
public actor PortableDevicesStorage: DeviceRegistryStorage {
    private let store: PortableConfigStore
    private let paths: AppPaths
    private let timeZone: TimeZone
    private var lastQuarantined: String?

    public init(store: PortableConfigStore, paths: AppPaths, timeZone: TimeZone = .current) {
        self.store = store; self.paths = paths; self.timeZone = timeZone
    }

    public func load() async throws -> Data? { try await store.read(.devices) }

    public func save(_ data: Data) async throws { try await store.write(.devices, data) }

    public func backupCorrupt(_ data: Data) async throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest != lastQuarantined else { return }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let base = "devices.json.corrupt-\(timestamp(Date()))"
        var url = paths.root.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = paths.root.appending(path: "\(base)-\(n)")
            n += 1
        }
        try data.write(to: url, options: .atomic)
        lastQuarantined = digest
    }

    private func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
