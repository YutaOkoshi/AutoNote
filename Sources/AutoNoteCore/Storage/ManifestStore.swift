import Foundation

public actor ManifestStore {
    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func save(_ manifest: Manifest) throws {
        try FileManager.default.createDirectory(at: paths.meetingDirectory(manifest.id), withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(manifest).write(to: paths.manifestFile(manifest.id), options: .atomic)
    }

    public func load(_ id: MeetingID) throws -> Manifest {
        try AutoNoteJSON.decoder().decode(Manifest.self, from: Data(contentsOf: paths.manifestFile(id)))
    }

    @discardableResult
    public func update(_ id: MeetingID, _ body: @Sendable (inout Manifest) -> Void) throws -> Manifest {
        var m = try load(id)
        body(&m)
        try save(m)
        return m
    }

    /// Newest `startedAt` first; unreadable manifests are skipped.
    public func all() -> [Manifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: paths.recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> Manifest? in
            guard let data = try? Data(contentsOf: dir.appending(path: "manifest.json")) else { return nil }
            return try? AutoNoteJSON.decoder().decode(Manifest.self, from: data)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    public func unfinishedRecordings() -> [Manifest] {
        all().filter { $0.status == .recording }
    }

    public func delete(_ id: MeetingID) throws {
        for url in [paths.meetingDirectory(id), paths.transcriptsDirectory(id), paths.vaultStateFile(id)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
