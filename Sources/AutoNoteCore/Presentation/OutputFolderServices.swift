import Foundation

/// The output-folder-bound services (`PortableConfigStore`, `VaultWriter`) for the folder currently in the
/// settings. Both come from `SharedVaultServices` so the queue stages, `delete` and the adapters share one
/// instance per folder (overview 8c, ruling X-T8a).
public actor OutputFolderServices {
    private let paths: AppPaths
    private let services: SharedVaultServices
    private var store: PortableConfigStore
    private var current: (folder: URL, writer: VaultWriter)?

    public init(paths: AppPaths, services: SharedVaultServices = .standard) {
        self.paths = paths
        self.services = services
        self.store = services.configStore(outputFolder: nil, paths: paths)
    }

    /// Switches to `outputFolder` (nil or empty: none) and syncs the portable files (§8b (4)).
    @discardableResult
    public func rebuild(outputFolder: String?) async throws -> PortableSyncReport {
        let folder = outputFolder.flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        store = services.configStore(outputFolder: folder, paths: paths)
        current = folder.map { ($0, services.vaultWriter(outputFolder: $0, paths: paths, now: { Date() })) }
        return try await store.sync()
    }

    public func portable() -> PortableConfigStore { store }

    /// nil when no output folder is set. The folder may still be missing on disk.
    public func vault() -> (folder: URL, writer: VaultWriter)? { current }
}

public actor QueueHolder {
    public private(set) var queue: PostProcessingQueue

    public init(_ q: PostProcessingQueue) { queue = q }

    public func replace(_ q: PostProcessingQueue) { queue = q }
}
