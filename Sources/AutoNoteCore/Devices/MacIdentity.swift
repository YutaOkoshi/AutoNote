import Foundation
import IOKit

/// Which Mac a registry entry was made on. `id` is `IOPlatformUUID`; `name` is the computer name and may change.
public struct MacIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id; self.name = name
    }
}

public protocol MacIdentityProviding: Sendable {
    func current() -> MacIdentity
}

public struct SystemMacIdentityProvider: MacIdentityProviding {
    public init() {}

    public func current() -> MacIdentity {
        MacIdentity(id: Self.platformUUID() ?? "unknown-mac", name: Host.current().localizedName ?? "Mac")
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }
}
