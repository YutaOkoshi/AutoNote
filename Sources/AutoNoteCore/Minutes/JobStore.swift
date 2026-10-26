import Foundation
import os

/// Persists queue jobs, one JSON file per meeting: `queueJobsDirectory/<meeting.rawValue>.json`.
public actor JobStore {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "JobStore")
    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    private func file(_ id: MeetingID) -> URL {
        paths.queueJobsDirectory.appending(path: "\(id.rawValue).json")
    }

    public func load(_ id: MeetingID) throws -> Job? {
        let url = file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AutoNoteJSON.decoder().decode(Job.self, from: Data(contentsOf: url))
    }

    public func save(_ job: Job) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.queueJobsDirectory, withIntermediateDirectories: true)
        let url = file(job.meeting)
        let tmp = paths.queueJobsDirectory.appending(path: "\(job.meeting.rawValue).\(UUID().uuidString).tmp")
        try AutoNoteJSON.encoder().encode(job).write(to: tmp)
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Oldest first by `(createdAt, id)`. Undecodable files are renamed to `<name>.broken` and skipped.
    public func all() throws -> [Job] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.queueJobsDirectory.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: paths.queueJobsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var jobs: [Job] = []
        for url in urls {
            do {
                jobs.append(try AutoNoteJSON.decoder().decode(Job.self, from: Data(contentsOf: url)))
            } catch {
                Self.logger.error("Setting aside unreadable job file \(url.lastPathComponent, privacy: .public)")
                let broken = URL(filePath: url.path + ".broken")
                try? fm.removeItem(at: broken)
                try? fm.moveItem(at: url, to: broken)
            }
        }
        return jobs.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func remove(_ id: MeetingID) throws {
        let url = file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
