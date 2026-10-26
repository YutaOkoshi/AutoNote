import Foundation
import os

public enum RetentionError: Error, Equatable {
    /// The meeting was written to the Vault, but its output folder is not set or not mounted.
    case outputFolderUnavailable
}

/// Audio retention and per-meeting deletion (要件書 §12).
public struct Retention: Sendable {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "Retention")
    private static let day: TimeInterval = 86_400

    private let paths: AppPaths
    private let services: SharedVaultServices

    public init(paths: AppPaths, services: SharedVaultServices = .standard) {
        self.paths = paths
        self.services = services
    }

    /// Deletes `tracks/` and `merged/` of meetings that ended more than `retentionDays` days before `now`
    /// (manifest, transcripts and the Vault stay). `0` keeps audio forever. A meeting still recording, too short,
    /// without `final.json`, or whose job has not completed `transcribe` keeps its audio.
    /// Returns the meetings whose audio was deleted by this call. A meeting that cannot be purged is logged and skipped.
    @discardableResult
    public func purgeExpiredAudio(retentionDays: Int, now: Date) async throws -> [MeetingID] {
        guard retentionDays > 0 else { return [] }
        let jobStore = JobStore(paths: paths)
        let fm = FileManager.default
        var purged: [MeetingID] = []
        for manifest in await ManifestStore(paths: paths).all() {
            let id = manifest.id
            let ended = manifest.endedAt ?? manifest.startedAt
            guard ended.addingTimeInterval(TimeInterval(retentionDays) * Self.day) < now,
                  manifest.status != .recording, manifest.status != .tooShort,
                  fm.fileExists(atPath: paths.transcriptFile(id, .final).path) else { continue }
            do {
                if let job = try await jobStore.load(id), !job.completedStages.contains(StageName.transcribe) { continue }
                var removed = false
                for dir in audioDirectories(id) where fm.fileExists(atPath: dir.path) {
                    try fm.removeItem(at: dir)
                    removed = true
                }
                if removed {
                    purged.append(id)
                    Self.logger.info("purge \(id.rawValue, privacy: .public): audio deleted")
                }
            } catch {
                Self.logger.error("purge \(id.rawValue, privacy: .public): skipped (\(String(describing: type(of: error)), privacy: .public))")
            }
        }
        return purged
    }

    /// Deletes everything of a meeting: its Vault file (found by `autonote_id` if renamed or moved) and index line,
    /// recordings, transcripts, Vault state and queue job. If it was written to the Vault but `outputFolder` is nil
    /// or missing, nothing is deleted and `.outputFolderUnavailable` is thrown.
    public func deleteMeeting(_ id: MeetingID, outputFolder: String?) async throws {
        let fm = FileManager.default
        let wasWritten = fm.fileExists(atPath: paths.vaultStateFile(id).path)
        var folder: URL?
        if let outputFolder {
            var isDir: ObjCBool = false
            let url = URL(filePath: outputFolder, directoryHint: .isDirectory)
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { folder = url }
        }
        if let folder {
            let writer = services.vaultWriter(outputFolder: folder, paths: paths, now: { Date() })
            try await writer.remove(id)
            _ = try await writer.rebuildIndex()
        } else if wasWritten {
            Self.logger.error("delete \(id.rawValue, privacy: .public): output folder unavailable, nothing deleted")
            throw RetentionError.outputFolderUnavailable
        }
        try await ManifestStore(paths: paths).delete(id)
        try await JobStore(paths: paths).remove(id)
        Self.logger.info("delete \(id.rawValue, privacy: .public): deleted")
    }

    private func audioDirectories(_ id: MeetingID) -> [URL] {
        [paths.tracksDirectory(id), paths.meetingDirectory(id).appending(path: "merged", directoryHint: .isDirectory)]
    }
}
