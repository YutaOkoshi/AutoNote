import Foundation

public enum OutputFolderOutcome: Equatable, Sendable {
    case unchanged
    case created(String)
    case failed
}

/// First-run defaults: where minutes are saved and whether the whisper `base` model is fetched.
public enum FirstRunDefaults {
    /// `<home>/Documents/AutoNote`, or `<paths.root>/vault` under `AUTONOTE_DATA_DIR`.
    public static func defaultOutputFolder(
        paths: AppPaths,
        isDataDirectoryOverridden: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if isDataDirectoryOverridden {
            return paths.root.appending(path: "vault", directoryHint: .isDirectory)
        }
        return home.appending(path: "Documents/AutoNote", directoryHint: .isDirectory)
    }

    public static func outputFolder(
        forInput input: String,
        paths: AppPaths,
        isDataDirectoryOverridden: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return pathString(defaultOutputFolder(paths: paths, isDataDirectoryOverridden: isDataDirectoryOverridden, home: home))
        }
        return trimmed
    }

    public static func modelToDownload(installed: [String], isDataDirectoryOverridden: Bool) -> String? {
        installed.isEmpty && !isDataDirectoryOverridden ? "base" : nil
    }

    @discardableResult
    public static func apply(
        settings: SettingsStore,
        paths: AppPaths,
        isDataDirectoryOverridden: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        createDirectory: @Sendable (URL) throws -> Void = { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
    ) async -> OutputFolderOutcome {
        do {
            let current = try await settings.load()
            guard current.outputFolder?.isEmpty ?? true else { return .unchanged }
            let folder = defaultOutputFolder(paths: paths, isDataDirectoryOverridden: isDataDirectoryOverridden, home: home)
            let path = pathString(folder)
            try createDirectory(folder)
            // Re-check inside the update: another writer may have set it since `load()`.
            try await settings.update { s in
                if s.outputFolder?.isEmpty ?? true { s.outputFolder = path }
            }
            return .created(path)
        } catch {
            return .failed
        }
    }

    private static func pathString(_ url: URL) -> String {
        var p = url.path(percentEncoded: false)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
