import CryptoKit
import Foundation
import Synchronization

public enum ModelError: Error, Equatable, Sendable {
    case unknownModel(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
}

/// Fans one download's progress out to every caller that joined it.
private final class ProgressFanout: Sendable {
    private let observers = Mutex<[@Sendable (Double) -> Void]>([])
    func add(_ observer: @escaping @Sendable (Double) -> Void) { observers.withLock { $0.append(observer) } }
    func send(_ value: Double) {
        let current = observers.withLock { $0 }
        for observer in current { observer(value) }
    }
}

public actor ModelManager {
    private let directory: URL
    private let catalog: [WhisperModel]
    private let downloader: any ModelDownloading
    private var inFlight: [String: (task: Task<URL, any Error>, fanout: ProgressFanout)] = [:]

    public init(
        directory: URL, catalog: [WhisperModel] = WhisperModelCatalog.all,
        downloader: any ModelDownloading = URLSessionModelDownloader()
    ) {
        self.directory = directory
        self.catalog = catalog
        self.downloader = downloader
    }

    /// Models whose file exists with exactly the catalog size (no hashing: see `verify`).
    public func installed() -> [WhisperModel] {
        catalog.filter { isInstalled($0) }
    }

    public func fileURL(for name: String) -> URL? {
        guard let model = catalog.first(where: { $0.name == name }), isInstalled(model) else { return nil }
        return directory.appending(path: model.fileName)
    }

    public func download(_ name: String, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        guard let model = catalog.first(where: { $0.name == name }) else { throw ModelError.unknownModel(name) }
        if let existing = inFlight[name] {
            existing.fanout.add(progress)
            return try await existing.task.value
        }
        let fanout = ProgressFanout()
        fanout.add(progress)
        let directory = directory
        let downloader = downloader
        let task = Task<URL, any Error> {
            try await Self.fetch(model, into: directory, using: downloader) { fanout.send($0) }
        }
        inFlight[name] = (task, fanout)
        defer { inFlight[name] = nil }
        return try await task.value
    }

    public func delete(_ name: String) throws {
        guard let model = catalog.first(where: { $0.name == name }) else { throw ModelError.unknownModel(name) }
        let fm = FileManager.default
        for file in [directory.appending(path: model.fileName), directory.appending(path: model.fileName + ".partial")]
        where fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    /// Full SHA-256 check of an installed file. `false` when missing, wrong size or wrong hash.
    public func verify(_ name: String) async throws -> Bool {
        guard let model = catalog.first(where: { $0.name == name }) else { throw ModelError.unknownModel(name) }
        guard isInstalled(model) else { return false }
        let file = directory.appending(path: model.fileName)
        let digest = try await Task.detached { try Self.sha256Hex(of: file) }.value
        return digest == model.sha256
    }

    // MARK: - Private

    private func isInstalled(_ model: WhisperModel) -> Bool {
        let path = directory.appending(path: model.fileName).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? NSNumber
        else { return false }
        return size.int64Value == model.sizeBytes
    }

    private static func fetch(
        _ model: WhisperModel, into directory: URL, using downloader: any ModelDownloading,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: model.fileName + ".partial")
        let final = directory.appending(path: model.fileName)
        try? fm.removeItem(at: partial)
        do {
            try await downloader.download(model.url, to: partial) { written, expected in
                let total = expected > 0 ? expected : model.sizeBytes
                progress(min(1, Double(written) / Double(max(total, 1))))
            }
            let actual = (try fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard actual == model.sizeBytes else {
                throw ModelError.sizeMismatch(expected: model.sizeBytes, actual: actual)
            }
            let digest = try await Task.detached { try sha256Hex(of: partial) }.value
            guard digest == model.sha256 else { throw ModelError.checksumMismatch }
            if fm.fileExists(atPath: final.path) {
                // Atomic swap: there is never a moment without a valid model file.
                _ = try fm.replaceItemAt(final, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: final)
            }
            progress(1.0)
            return final
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done = false
        while !done {
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    done = true
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
