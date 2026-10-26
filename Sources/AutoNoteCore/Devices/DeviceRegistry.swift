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

public actor DeviceRegistry {
    private let storage: any DeviceRegistryStorage
    private let mac: any MacIdentityProviding
    private let now: @Sendable () -> Date
    private var items: [RegisteredDevice] = []

    public init(storage: any DeviceRegistryStorage, mac: any MacIdentityProviding,
                now: @Sendable @escaping () -> Date = Date.init) {
        self.storage = storage; self.mac = mac; self.now = now
    }

    /// A missing file, a legacy top-level `[]`, or an unreadable file all leave an empty registry;
    /// unreadable content is first handed to `backupCorrupt`.
    public func reload() async {
        items = []
        guard let data = try? await storage.load() else { return }
        if let file = try? AutoNoteJSON.decoder().decode(DeviceRegistryFile.self, from: data) {
            items = file.devices
        } else if let legacy = try? AutoNoteJSON.decoder().decode([RegisteredDevice].self, from: data) {
            items = legacy
        } else {
            try? await storage.backupCorrupt(data)
        }
    }

    public func entries() -> [RegisteredDevice] { items }

    public func match(_ device: DeviceIdentity) -> RegistryMatch {
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
               let hit = items.first(where: {
                   $0.disposition == .registered && $0.transport == .usb && $0.modelUID == model && $0.name == device.name
               }) {
                return resolve(hit, .modelUIDAndName)
            }
        case .bluetooth:
            if let hit = items.first(where: {
                $0.disposition == .registered && $0.transport == .bluetooth && $0.name == device.name
            }) {
                return resolve(hit, .name)
            }
        default:
            break
        }
        return .unknown
    }

    @discardableResult
    public func register(_ device: DeviceIdentity, startOnModelMatchDefault: Bool = false) async throws -> RegisteredDevice {
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

    public func ignore(_ device: DeviceIdentity) async throws {
        if let index = items.firstIndex(where: { $0.deviceUID == device.deviceUID }) {
            var entry = items[index]
            entry.disposition = .ignored
            try await commit(entry, at: index)
        } else {
            try await append(device, disposition: .ignored, startOnModelMatch: false)
        }
    }

    public func remove(entryID: String) async throws {
        guard let index = items.firstIndex(where: { $0.id == entryID }) else {
            throw DeviceRegistryError.unknownEntry(entryID)
        }
        var next = items
        next.remove(at: index)
        try await persist(next)
        items = next
    }

    public func setDisposition(entryID: String, _ d: DeviceDisposition) async throws {
        let index = try indexOf(entryID)
        var entry = items[index]
        entry.disposition = d
        try await commit(entry, at: index)
    }

    public func setStartOnModelMatch(entryID: String, _ on: Bool) async throws {
        let index = try indexOf(entryID)
        var entry = items[index]
        entry.startOnModelMatch = on
        try await commit(entry, at: index)
    }

    // MARK: - Helpers

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
        let url = paths.root.appending(path: "devices.json.corrupt-\(timestamp(Date()))")
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
