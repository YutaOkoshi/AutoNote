import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct DeviceRegistryTests {
    static let macA = MacIdentity(id: "MAC-A", name: "Fictional Mac A")
    static let macB = MacIdentity(id: "MAC-B", name: "Fictional Mac B")

    static let bt = DeviceIdentity(name: "Headset X", deviceUID: "00-11-22-33-44-55:input", modelUID: "0 0",
                                   transport: .bluetooth, inputChannels: 1, uidKind: .individual)
    static let jack = DeviceIdentity(name: "Fictional Headphone Jack", deviceUID: "BuiltInHeadphoneInputDevice",
                                     modelUID: "Codec Input", transport: .builtin, inputChannels: 1, uidKind: .fixed)

    static func usb(_ serial: String, kind: UIDKind = .individual) -> DeviceIdentity {
        DeviceIdentity(name: "Fictional USB Headset", deviceUID: "AppleUSBAudioEngine:Fict:Head:\(serial):1",
                       modelUID: "Fictional Audio", transport: .usb, inputChannels: 1, uidKind: kind)
    }

    func makeRegistry(storage: InMemoryRegistryStorage = InMemoryRegistryStorage(), mac: MacIdentity = macA)
        -> (DeviceRegistry, InMemoryRegistryStorage) {
        (DeviceRegistry(storage: storage, mac: FakeMacIdentity(mac)), storage)
    }

    @Test func exactInputUIDMatches() async throws {
        let (registry, _) = makeRegistry()
        let entry = try await registry.register(Self.bt)
        #expect(await registry.match(Self.bt) == .registered(entryID: entry.id, rule: .deviceUID))
    }

    @Test func ignoredDeviceMatchesIgnored() async throws {
        let (registry, _) = makeRegistry()
        try await registry.ignore(Self.jack)
        let id = await registry.entries()[0].id
        #expect(await registry.match(Self.jack) == .ignored(entryID: id))
        #expect(await registry.entries()[0].startOnModelMatch == false)
    }

    @Test func usbSameModelOtherUnitFollowsSetting() async throws {
        let (registry, _) = makeRegistry()
        let a = try await registry.register(Self.usb("SERIAL-A"))
        let b = Self.usb("SERIAL-B")
        #expect(await registry.match(b) == .unknown)
        try await registry.setStartOnModelMatch(entryID: a.id, true)
        #expect(await registry.match(b) == .registered(entryID: a.id, rule: .modelUIDAndName))
    }

    @Test func portBasedUSBDefaultsToModelMatchOn() async throws {
        let (registry, _) = makeRegistry()
        let port = try await registry.register(Self.usb("00140000", kind: .portBased))
        #expect(port.startOnModelMatch)
        let (r2, _) = makeRegistry()
        #expect(try await r2.register(Self.usb("S1")).startOnModelMatch == false)
        let (r3, _) = makeRegistry()
        #expect(try await r3.register(Self.usb("S1"), startOnModelMatchDefault: true).startOnModelMatch)
    }

    @Test func bluetoothZeroModelUIDIsNeverAModelMatch() async throws {
        let (registry, _) = makeRegistry()
        let x = try await registry.register(Self.bt, startOnModelMatchDefault: true)
        let y = DeviceIdentity(name: "Headset Y", deviceUID: "AA-BB-CC-DD-EE-FF:input", modelUID: "0 0",
                               transport: .bluetooth, inputChannels: 1, uidKind: .individual)
        #expect(await registry.match(y) == .unknown)
        var sameName = Self.bt
        sameName.deviceUID = "99-99-99-99-99-99:input"
        #expect(await registry.match(sameName) == .registered(entryID: x.id, rule: .name))
    }

    @Test func usbWithZeroOrNilModelUIDIsNeverAModelMatch() async throws {
        let (registry, _) = makeRegistry()
        var a = Self.usb("A"); a.modelUID = "0 0"
        _ = try await registry.register(a, startOnModelMatchDefault: true)
        var b = Self.usb("B"); b.modelUID = "0 0"
        #expect(await registry.match(b) == .unknown)
        var c = Self.usb("C"); c.modelUID = nil
        #expect(await registry.match(c) == .unknown)
    }

    @Test func otherMacNameMatchSuggestsReRegistration() async throws {
        let storage = InMemoryRegistryStorage()
        let (onB, _) = makeRegistry(storage: storage, mac: Self.macB)
        let entry = try await onB.register(Self.bt)
        let (onA, _) = makeRegistry(storage: storage, mac: Self.macA)
        await onA.reload()
        var other = Self.bt
        other.deviceUID = "99-99-99-99-99-99:input"
        #expect(await onA.match(other) == .reRegistrationSuggested(entryID: entry.id))
        // Rule 1 ignores which Mac registered it.
        #expect(await onA.match(Self.bt) == .registered(entryID: entry.id, rule: .deviceUID))
    }

    @Test func sameMacRenamedStillCountsAsSameMac() async throws {
        let storage = InMemoryRegistryStorage()
        let (r1, _) = makeRegistry(storage: storage, mac: Self.macA)
        let entry = try await r1.register(Self.bt, startOnModelMatchDefault: true)
        let renamed = MacIdentity(id: Self.macA.id, name: "Renamed")
        let (r2, _) = makeRegistry(storage: storage, mac: renamed)
        await r2.reload()
        var other = Self.bt
        other.deviceUID = "99-99-99-99-99-99:input"
        #expect(await r2.match(other) == .registered(entryID: entry.id, rule: .name))
    }

    @Test func registerExistingUIDReusesEntry() async throws {
        let (registry, _) = makeRegistry()
        try await registry.ignore(Self.bt)
        let ignoredID = await registry.entries()[0].id
        var renamed = Self.bt
        renamed.name = "Headset X renamed"
        let entry = try await registry.register(renamed)
        #expect(entry.id == ignoredID)
        #expect(entry.disposition == .registered)
        #expect(entry.name == "Headset X renamed")
        #expect(await registry.entries().count == 1)
    }

    @Test func mutatorsThrowOnUnknownEntry() async throws {
        let (registry, _) = makeRegistry()
        await #expect(throws: DeviceRegistryError.unknownEntry("nope")) { try await registry.remove(entryID: "nope") }
        await #expect(throws: DeviceRegistryError.unknownEntry("nope")) { try await registry.setDisposition(entryID: "nope", .ignored) }
        await #expect(throws: DeviceRegistryError.unknownEntry("nope")) { try await registry.setStartOnModelMatch(entryID: "nope", true) }
    }

    @Test func removeAndSetDispositionPersist() async throws {
        let storage = InMemoryRegistryStorage()
        let (registry, _) = makeRegistry(storage: storage)
        let a = try await registry.register(Self.bt)
        let b = try await registry.register(Self.jack)
        try await registry.setDisposition(entryID: b.id, .ignored)
        try await registry.remove(entryID: a.id)
        let (fresh, _) = makeRegistry(storage: storage)
        await fresh.reload()
        let entries = await fresh.entries()
        #expect(entries.map(\.id) == [b.id])
        #expect(entries[0].disposition == .ignored)
    }

    @Test func fileRoundTripsWithSnakeCaseKeys() async throws {
        let storage = InMemoryRegistryStorage()
        let (registry, _) = makeRegistry(storage: storage)
        _ = try await registry.register(Self.bt)
        _ = try await registry.register(Self.usb("S1"))
        let json = String(decoding: try #require(await storage.data), as: UTF8.self)
        for key in ["\"device_uid\"", "\"model_uid\"", "\"registered_on\"", "\"start_on_model_match\"",
                    "\"uid_kind\"", "\"registered_at\"", "\"version\" : 1"] {
            #expect(json.contains(key), "missing \(key)")
        }
        let (fresh, _) = makeRegistry(storage: storage)
        await fresh.reload()
        #expect(await fresh.entries() == registry.entries())
    }

    @Test func missingFileMeansEmptyRegistry() async {
        let (registry, _) = makeRegistry()
        await registry.reload()
        #expect(await registry.entries().isEmpty)
        #expect(await registry.match(Self.bt) == .unknown)
    }

    @Test func legacyEmptyArrayMeansEmptyRegistryAndIsRewritten() async throws {
        let storage = InMemoryRegistryStorage(initial: Data("[]\n".utf8))
        let (registry, _) = makeRegistry(storage: storage)
        await registry.reload()
        #expect(await registry.entries().isEmpty)
        #expect(await storage.backups.isEmpty)
        _ = try await registry.register(Self.bt)
        let json = String(decoding: try #require(await storage.data), as: UTF8.self)
        #expect(json.contains("\"devices\""))
        #expect(json.contains("\"version\" : 1"))
    }

    @Test func corruptFileIsBackedUpAndRegistryStartsEmpty() async throws {
        let bytes = Data("{not json".utf8)
        let storage = InMemoryRegistryStorage(initial: bytes)
        let (registry, _) = makeRegistry(storage: storage)
        await registry.reload()
        #expect(await registry.entries().isEmpty)
        #expect(await storage.backups == [bytes])
        _ = try await registry.register(Self.bt)
        let saved = try #require(await storage.data)
        let decoded = try JSONSerialization.jsonObject(with: saved) as? [String: Any]
        #expect((decoded?["devices"] as? [Any])?.count == 1)
    }

    @Test func missingOutputFolderUsesMirror() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appending(path: "app", directoryHint: .isDirectory))
        let missing = root.appending(path: "no-such-vault", directoryHint: .isDirectory)
        let store = PortableConfigStore(paths: paths, outputFolder: missing)
        let registry = DeviceRegistry(storage: PortableDevicesStorage(store: store, paths: paths),
                                      mac: FakeMacIdentity(Self.macA))
        let entry = try await registry.register(Self.bt)
        #expect(FileManager.default.fileExists(atPath: paths.portableMirrorDirectory.appending(path: "devices.json").path))
        let fresh = DeviceRegistry(storage: PortableDevicesStorage(store: store, paths: paths),
                                   mac: FakeMacIdentity(Self.macA))
        await fresh.reload()
        #expect(await fresh.match(Self.bt) == .registered(entryID: entry.id, rule: .deviceUID))
    }

    @Test func portableStorageQuarantinesCorruptContentOnce() async throws {
        let root = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appending(path: "app", directoryHint: .isDirectory))
        let store = PortableConfigStore(paths: paths, outputFolder: nil)
        try await store.write(.devices, Data("{not json".utf8))
        let storage = PortableDevicesStorage(store: store, paths: paths,
                                             timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let registry = DeviceRegistry(storage: storage, mac: FakeMacIdentity(Self.macA))
        await registry.reload()
        await registry.reload()
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .filter { $0.hasPrefix("devices.json.corrupt-") }
        #expect(backups.count == 1)
        let backed = try Data(contentsOf: paths.root.appending(path: backups[0]))
        #expect(backed == Data("{not json".utf8))
    }

    @Test func defaultDevicesFileDecodesAsEmptyRegistry() async throws {
        let bytes = try #require(PortableDefaults.standard[.devices])
        let storage = InMemoryRegistryStorage(initial: bytes)
        let (registry, _) = makeRegistry(storage: storage)
        await registry.reload()
        #expect(await registry.entries().isEmpty)
        #expect(await storage.backups.isEmpty)
        let encoded = try AutoNoteJSON.encoder().encode(DeviceRegistryFile(version: 1, devices: []))
        #expect(encoded + Data("\n".utf8) == bytes)
    }
}
