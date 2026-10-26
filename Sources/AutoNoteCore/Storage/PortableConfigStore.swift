import Foundation

public enum PortableFile: String, CaseIterable, Sendable {
    case dictionary = "dictionary.md"
    case prompt = "prompt.md"
    case frontmatter = "frontmatter.md"
    case devices = "devices.json"
}

public enum PortableDefaults {
    /// Plan 05 adds the `prompt` default; plan 03 defines the shape of `devices.json`.
    public static let standard: [PortableFile: Data] = [
        .dictionary: Data(DictionaryFile.defaultMarkdown.utf8),
        .frontmatter: Data(FrontmatterTemplate.defaultText.utf8),
        .devices: Data("[]\n".utf8),
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

    public func sync() throws -> PortableSyncReport {
        let fm = FileManager.default
        var report = PortableSyncReport(outputAvailable: isOutputAvailable)
        try fm.createDirectory(at: paths.portableMirrorDirectory, withIntermediateDirectories: true)
        guard let vaultDir = vaultDirectory, report.outputAvailable else {
            for file in PortableFile.allCases where !fm.fileExists(atPath: mirrorURL(file).path) {
                guard let data = defaults[file] else { continue }
                try put(data, at: mirrorURL(file), modified: nil)
                report.createdDefaults.append(file)
            }
            return report
        }
        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        for file in PortableFile.allCases {
            let vault = vaultURL(file, in: vaultDir), mirror = mirrorURL(file)
            let vaultDate = Self.modificationDate(vault), mirrorDate = Self.modificationDate(mirror)
            switch (vaultDate, mirrorDate) {
            case let (vd?, md?):
                if try Data(contentsOf: vault) == Data(contentsOf: mirror) { continue }
                if md > vd {
                    try put(Data(contentsOf: mirror), at: vault, modified: md)
                    report.toVault.append(file)
                } else {
                    try put(Data(contentsOf: vault), at: mirror, modified: vd)
                    report.toMirror.append(file)
                }
            case let (vd?, nil):
                try put(Data(contentsOf: vault), at: mirror, modified: vd)
                report.toMirror.append(file)
            case let (nil, md?):
                try put(Data(contentsOf: mirror), at: vault, modified: md)
                report.toVault.append(file)
            case (nil, nil):
                guard let data = defaults[file] else { continue }
                let now = Date()
                try put(data, at: vault, modified: now)
                try put(data, at: mirror, modified: now)
                report.createdDefaults.append(file)
            }
        }
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
        }
    }

    // MARK: - Helpers

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
