import Foundation
import os

/// Finds recordings left in `.recording` by a crash, repairs their WAV headers and manifest, or discards them.
public struct CrashRecovery: Sendable {
    private let paths: AppPaths
    private let manifests: ManifestStore
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "CrashRecovery")

    public init(paths: AppPaths, manifests: ManifestStore) {
        self.paths = paths
        self.manifests = manifests
    }

    /// Meant to run at launch, before recording starts; `active` guards against picking up a live recording.
    public func findInterrupted(excluding active: MeetingID? = nil) async throws -> [Manifest] {
        await manifests.unfinishedRecordings().filter { $0.id != active }
    }

    public func recover(_ id: MeetingID) async throws -> Manifest {
        var manifest = try await manifests.load(id)
        let directory = paths.meetingDirectory(id)

        var survivors: [TrackFile] = []
        for var file in manifest.tracks {
            let url = directory.appending(path: file.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let repaired: WAVInfo?
            do {
                repaired = try WAVFile.repairHeader(url)
            } catch is WAVFileError {
                Self.logger.error("dropping track file with corrupt header: \(file.relativePath, privacy: .public)")
                continue
            }
            guard let info = repaired, info.dataBytes > 0 else { continue }
            file.durationSeconds = info.durationSeconds
            survivors.append(file)
        }
        manifest.tracks = survivors

        let end = survivors.map { $0.startOffset.seconds + ($0.durationSeconds ?? 0) }.max() ?? 0
        manifest.pauses = manifest.pauses.map { pause in
            var p = pause
            if p.end == nil { p.end = TimelineTime(seconds: end) }
            return p
        }
        manifest.endedAt = manifest.startedAt.addingTimeInterval(end)
        manifest.status = end < RecordingSession.minimumDurationSeconds ? .tooShort : .recorded
        try await manifests.save(manifest)
        return manifest
    }

    public func discard(_ id: MeetingID) async throws {
        try await manifests.delete(id)
    }
}
