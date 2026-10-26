import Foundation
import CryptoKit

public enum PortableFile: String, CaseIterable, Sendable {
    case dictionary = "dictionary.md"
    case prompt = "prompt.md"
    case frontmatter = "frontmatter.md"
    case devices = "devices.json"
}

public enum PortableDefaults {
    /// `devices.json` holds `{"version": 1, "devices": [...]}` (plan 03).
    public static let standard: [PortableFile: Data] = [
        .dictionary: Data(DictionaryFile.defaultMarkdown.utf8),
        .prompt: Data(DefaultPrompt.instructions.utf8),
        .frontmatter: Data(FrontmatterTemplate.defaultText.utf8),
        .devices: Data("{\n  \"devices\" : [\n\n  ],\n  \"version\" : 1\n}\n".utf8),
    ]
}

public struct PortableSyncReport: Equatable, Sendable {
    public var outputAvailable: Bool
    public var toMirror: [PortableFile]
    public var toVault: [PortableFile]
    public var createdDefaults: [PortableFile]

    public init(outputAvailable: Bool, toMirror: [PortableFile] = [], toVault: [PortableFile] = [], createdDefaults: [PortableFile] = []) {
        self.outputAvailable = outputAvailable
        self.toMirror = toMirror
        self.toVault = toVault
        self.createdDefaults = createdDefaults
    }
}

/// Keeps `<output folder>/_autonote/` and the app-side mirror in step (spec 9.5).
public actor PortableConfigStore {
    private let paths: AppPaths
    private let outputFolder: URL?
    private let defaults: [PortableFile: Data]

    public init(paths: AppPaths, outputFolder: URL?, defaults: [PortableFile: Data] = PortableDefaults.standard) {
        self.paths = paths
        self.outputFolder = outputFolder
        self.defaults = defaults
    }

    public var isOutputAvailable: Bool { Self.directoryExists(outputFolder) }

    /// Per file (`allCases` order) when the output folder is available:
    /// - same content on both sides → nothing to copy;
    /// - only one side has it → copy it to the other; neither → write the default to both;
    /// - both differ → the Vault wins when the mirror is unchanged since the last sync or the mirror was
    ///   synced with another folder (or none); the mirror wins when the Vault is unchanged since the last
    ///   sync; both changed → newer modification date, tie → Vault.
    /// Defaults written while the folder is unavailable are recorded as synced, so they never overwrite a real Vault.
    public func sync() throws -> PortableSyncReport {
        let fm = FileManager.default
        var report = PortableSyncReport(outputAvailable: isOutputAvailable)
        try fm.createDirectory(at: paths.portableMirrorDirectory, withIntermediateDirectories: true)
        var state = loadState()
        guard let vaultDir = vaultDirectory, let folderKey, report.outputAvailable else {
            for file in PortableFile.allCases where !fm.fileExists(atPath: mirrorURL(file).path) {
                guard let data = defaults[file] else { continue }
                try put(data, at: mirrorURL(file), modified: nil)
                state.files[file.rawValue] = .init(lastSyncedSha256: Self.sha256(data))
                report.createdDefaults.append(file)
            }
            try saveState(state)
            return report
        }
        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        let sameFolder = state.outputFolder == folderKey
        for file in PortableFile.allCases {
            let vault = vaultURL(file, in: vaultDir), mirror = mirrorURL(file)
            let vaultData = fm.fileExists(atPath: vault.path) ? try Data(contentsOf: vault) : nil
            let mirrorData = fm.fileExists(atPath: mirror.path) ? try Data(contentsOf: mirror) : nil
            let synced: Data?
            switch (vaultData, mirrorData) {
            case let (v?, m?):
                if v == m { synced = v; break }
                let last = sameFolder ? state.files[file.rawValue]?.lastSyncedSha256 : nil
                let vaultWins: Bool
                if !sameFolder || Self.sha256(m) == last {
                    vaultWins = true
                } else if Self.sha256(v) == last {
                    vaultWins = false
                } else {
                    let vd = Self.modificationDate(vault) ?? .distantPast, md = Self.modificationDate(mirror) ?? .distantPast
                    vaultWins = vd >= md
                }
                if vaultWins {
                    try put(v, at: mirror, modified: Self.modificationDate(vault))
                    report.toMirror.append(file)
                    synced = v
                } else {
                    try put(m, at: vault, modified: Self.modificationDate(mirror))
                    report.toVault.append(file)
                    synced = m
                }
            case let (v?, nil):
                try put(v, at: mirror, modified: Self.modificationDate(vault))
                report.toMirror.append(file)
                synced = v
            case let (nil, m?):
                try put(m, at: vault, modified: Self.modificationDate(mirror))
                report.toVault.append(file)
                synced = m
            case (nil, nil):
                guard let data = defaults[file] else { synced = nil; break }
                let now = Date()
                try put(data, at: vault, modified: now)
                try put(data, at: mirror, modified: now)
                report.createdDefaults.append(file)
                synced = data
            }
            state.files[file.rawValue] = synced.map { .init(lastSyncedSha256: Self.sha256($0)) }
        }
        state.outputFolder = folderKey
        try saveState(state)
        return report
    }

    public func read(_ file: PortableFile) throws -> Data? {
        if let dir = vaultDirectory, isOutputAvailable {
            let url = vaultURL(file, in: dir)
            if FileManager.default.fileExists(atPath: url.path) { return try Data(contentsOf: url) }
        }
        let mirror = mirrorURL(file)
        return FileManager.default.fileExists(atPath: mirror.path) ? try Data(contentsOf: mirror) : nil
    }

    public func write(_ file: PortableFile, _ data: Data) throws {
        let now = Date()
        try FileManager.default.createDirectory(at: paths.portableMirrorDirectory, withIntermediateDirectories: true)
        try put(data, at: mirrorURL(file), modified: now)
        if let dir = vaultDirectory, isOutputAvailable {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try put(data, at: vaultURL(file, in: dir), modified: now)
            // Both sides now hold `data`. A state kept for another folder is left alone: the next sync
            // re-baselines against this folder. An offline write never touches the state, so the next
            // sync sees the mirror as changed.
            var state = loadState()
            if state.outputFolder == folderKey {
                state.files[file.rawValue] = .init(lastSyncedSha256: Self.sha256(data))
                try saveState(state)
            }
        }
    }

    // MARK: - Helpers

    /// `portable-mirror/.sync-state.json`: which folder the mirror was last synced with, and each file's content then.
    struct SyncState: Codable, Equatable {
        struct FileState: Codable, Equatable { var lastSyncedSha256: String }
        var outputFolder: String?
        var files: [String: FileState]

        init(outputFolder: String? = nil, files: [String: FileState] = [:]) {
            self.outputFolder = outputFolder; self.files = files
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder)
            files = try c.decodeIfPresent([String: FileState].self, forKey: .files) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(outputFolder, forKey: .outputFolder)
            try c.encode(files, forKey: .files)
        }

        private enum CodingKeys: String, CodingKey { case outputFolder, files }
    }

    private var stateURL: URL { paths.portableMirrorDirectory.appending(path: ".sync-state.json") }

    /// A missing or unreadable state counts as "never synced".
    private func loadState() -> SyncState {
        guard let data = try? Data(contentsOf: stateURL) else { return SyncState() }
        return (try? AutoNoteJSON.decoder().decode(SyncState.self, from: data)) ?? SyncState()
    }

    private func saveState(_ state: SyncState) throws {
        try AutoNoteJSON.encoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private var folderKey: String? { outputFolder?.resolvingSymlinksInPath().standardizedFileURL.path }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var vaultDirectory: URL? { outputFolder?.appending(path: "_autonote", directoryHint: .isDirectory) }
    private func vaultURL(_ file: PortableFile, in dir: URL) -> URL { dir.appending(path: file.rawValue) }
    private func mirrorURL(_ file: PortableFile) -> URL { paths.portableMirrorDirectory.appending(path: file.rawValue) }

    private func put(_ data: Data, at url: URL, modified: Date?) throws {
        try data.write(to: url, options: .atomic)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private static func directoryExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
