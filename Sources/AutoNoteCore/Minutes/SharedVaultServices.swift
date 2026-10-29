import Foundation
import Synchronization

/// Hands out one `VaultWriter` / `PortableConfigStore` actor per output folder, so every queue stage that
/// touches the same Vault goes through the same actor.
public final class SharedVaultServices: Sendable {
    public static let standard = SharedVaultServices()

    private struct Key: Hashable {
        var outputFolder: String?
        var root: String
    }

    private let writers = Mutex<[Key: VaultWriter]>([:])
    private let configStores = Mutex<[Key: PortableConfigStore]>([:])

    public init() {}

    /// The first call for a folder decides `now`; later calls for the same folder get the cached writer.
    public func vaultWriter(outputFolder: URL, paths: AppPaths, now: @escaping @Sendable () -> Date) -> VaultWriter {
        let key = Self.key(outputFolder, paths)
        return writers.withLock { cache in
            if let writer = cache[key] { return writer }
            let writer = VaultWriter(outputFolder: outputFolder, paths: paths, now: now)
            cache[key] = writer
            return writer
        }
    }

    public func configStore(outputFolder: URL?, paths: AppPaths) -> PortableConfigStore {
        let key = Self.key(outputFolder, paths)
        return configStores.withLock { cache in
            if let store = cache[key] { return store }
            let store = PortableConfigStore(paths: paths, outputFolder: outputFolder)
            cache[key] = store
            return store
        }
    }

    private static func key(_ outputFolder: URL?, _ paths: AppPaths) -> Key {
        Key(outputFolder: outputFolder?.standardizedFileURL.path, root: paths.root.path)
    }
}
