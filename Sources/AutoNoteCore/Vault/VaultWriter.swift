import Foundation
import CryptoKit

public enum VaultError: Error, Equatable {
    case outputFolderUnavailable(URL)
}

public enum VaultWriteOutcome: Equatable, Sendable {
    case written(URL)
    case conflict(URL)
}

public enum OverwritePolicy: Sendable {
    case ifUnchanged, force
}

public struct VaultWriteRecord: Codable, Equatable, Sendable {
    public var meeting: MeetingID
    public var relativePath: String
    public var sha256: String
    public var writtenAt: Date

    public init(meeting: MeetingID, relativePath: String, sha256: String, writtenAt: Date) {
        self.meeting = meeting; self.relativePath = relativePath; self.sha256 = sha256; self.writtenAt = writtenAt
    }
}

public actor VaultWriter {
    private let outputFolder: URL
    private let paths: AppPaths
    private let now: @Sendable () -> Date

    public init(outputFolder: URL, paths: AppPaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.outputFolder = outputFolder.resolvingSymlinksInPath()
        self.paths = paths
        self.now = now
    }

    public func write(_ document: MeetingDocument, policy: OverwritePolicy = .ifUnchanged, renameToMatchTitle: Bool = false) throws -> VaultWriteOutcome {
        try requireOutputFolder()
        let fm = FileManager.default
        let id = document.manifest.id
        let existing = try existingFile(for: id)
        let record = record(for: id)
        let yearDir = outputFolder.appending(path: document.yearFolder, directoryHint: .isDirectory)

        var target: URL
        if let existing {
            if policy == .ifUnchanged {
                let current = try Self.sha256(Data(contentsOf: existing))
                if record == nil || record?.sha256 != current { return .conflict(existing) }
            }
            target = existing
            let promote = MeetingFileName.isUntitled(existing.lastPathComponent) && document.hasTitle && document.manifest.status != .transcriptOnly
            if promote || renameToMatchTitle {
                target = Self.uniqueURL(document.preferredFileName, in: yearDir, ignoring: existing)
            }
        } else {
            target = Self.uniqueURL(document.preferredFileName, in: yearDir, ignoring: nil)
        }

        let data = Data(document.render().utf8)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        if let existing, existing != target { try? fm.removeItem(at: existing) }
        try save(VaultWriteRecord(meeting: id, relativePath: relativePath(of: target), sha256: Self.sha256(data), writtenAt: now()))
        return .written(target)
    }

    public func rebuildIndex() throws -> URL {
        try requireOutputFolder()
        let entries = try VaultScanner.scan(outputFolder: outputFolder)
        let index = outputFolder.appending(path: "_index.md")
        try Data(IndexFile.render(entries).utf8).write(to: index, options: .atomic)
        return index
    }

    public func remove(_ id: MeetingID) throws {
        let fm = FileManager.default
        if let rec = record(for: id) {
            let file = outputFolder.appending(path: rec.relativePath)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        } else {
            for file in try locateAll(id) { try fm.removeItem(at: file) }
        }
        let stateFile = paths.vaultStateFile(id)
        if fm.fileExists(atPath: stateFile.path) { try fm.removeItem(at: stateFile) }
    }

    public func record(for id: MeetingID) -> VaultWriteRecord? {
        guard let data = try? Data(contentsOf: paths.vaultStateFile(id)) else { return nil }
        return try? AutoNoteJSON.decoder().decode(VaultWriteRecord.self, from: data)
    }

    // MARK: - Helpers

    private func requireOutputFolder() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputFolder.path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError.outputFolderUnavailable(outputFolder)
        }
    }

    private func existingFile(for id: MeetingID) throws -> URL? {
        if let rec = record(for: id) {
            let file = outputFolder.appending(path: rec.relativePath)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return try locateAll(id).first
    }

    /// Scanner URLs can spell the folder differently (`/private/var` vs `/var`); re-root them on `outputFolder`.
    private func locateAll(_ id: MeetingID) throws -> [URL] {
        try VaultScanner.locate(id, in: outputFolder).map {
            outputFolder.appending(path: relativePath(of: $0.resolvingSymlinksInPath()))
        }
    }

    private func save(_ record: VaultWriteRecord) throws {
        try FileManager.default.createDirectory(at: paths.vaultStateDirectory, withIntermediateDirectories: true)
        try AutoNoteJSON.encoder().encode(record).write(to: paths.vaultStateFile(record.meeting), options: .atomic)
    }

    private func relativePath(of file: URL) -> String {
        let prefix = outputFolder.path.hasSuffix("/") ? outputFolder.path : outputFolder.path + "/"
        let path = file.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func uniqueURL(_ fileName: String, in dir: URL, ignoring: URL?) -> URL {
        let name = MeetingFileName.unique(fileName) { candidate in
            let url = dir.appending(path: candidate)
            return url != ignoring && FileManager.default.fileExists(atPath: url.path)
        }
        return dir.appending(path: name)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
