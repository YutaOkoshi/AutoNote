import Foundation

/// Downloads and deletes translation models, and refuses to download before the license is accepted (spec 2:
/// nothing is fetched until the person agrees). The settings screen goes through this, never the manager directly.
public struct TranslationModelInstaller: Sendable {
    public let manager: TranslationModelManager
    private let settings: @Sendable () async -> Settings

    public init(manager: TranslationModelManager, settings: @Sendable @escaping () async -> Settings) {
        self.manager = manager
        self.settings = settings
    }

    public func download(_ name: String, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        guard TranslationLicense.isAccepted(await settings()) else { throw TranslationError.licenseNotAccepted }
        return try await manager.download(name, progress: progress)
    }

    public func delete(_ name: String) async throws { try await manager.delete(name) }

    public func installed() async -> [TranslationModel] { await manager.installed() }

    /// The installed file of `model`, nil when it is missing.
    public func fileURL(_ model: TranslationModel) async -> URL? { await manager.fileURL(for: model.name) }
}
