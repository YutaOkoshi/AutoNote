import Foundation
import os

/// Rebuilds the Vault's `_index.md` through the shared `VaultWriter` (spec §9.6). An unset or unavailable
/// output folder, or any I/O error, retries every five minutes.
public struct UpdateIndexStage: QueueStage {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "UpdateIndexStage")

    public let name = StageName.updateIndex
    public static let retryInterval: TimeInterval = 300
    private let services: SharedVaultServices

    public init(services: SharedVaultServices = .standard) {
        self.services = services
    }

    public func run(_ job: inout Job, context: StageContext) async throws {
        let id = job.meeting
        guard let folderPath = context.settings.outputFolder else {
            Self.logger.notice("\(id.rawValue, privacy: .public): output folder not set, retry later")
            throw StageError.retry(after: Self.retryInterval, reason: "output_folder_missing")
        }
        let outputFolder = URL(filePath: folderPath, directoryHint: .isDirectory)
        let writer = services.vaultWriter(outputFolder: outputFolder, paths: context.paths, now: context.now)
        do {
            _ = try await writer.rebuildIndex()
        } catch is CancellationError {
            throw CancellationError()
        } catch VaultError.outputFolderUnavailable {
            Self.logger.notice("\(id.rawValue, privacy: .public): output folder unavailable, retry later")
            throw StageError.retry(after: Self.retryInterval, reason: "output_folder_unavailable")
        } catch {
            let kind = String(describing: type(of: error))
            Self.logger.error("\(id.rawValue, privacy: .public): index rebuild failed (\(kind, privacy: .public))")
            throw StageError.retry(after: Self.retryInterval, reason: kind)
        }
        Self.logger.info("\(id.rawValue, privacy: .public): index rebuilt")
    }
}
