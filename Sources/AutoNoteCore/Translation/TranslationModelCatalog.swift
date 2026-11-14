import Foundation

/// A PLaMo 3 Translate GGUF from PFN's own Hugging Face repository, pinned to one revision and one SHA-256
/// (spec 2: PFN replaced the GGUF files after release). Never re-quantized or redistributed by AutoNote.
public struct TranslationModel: Codable, Equatable, Hashable, Sendable, DownloadableModel {
    /// `0.8b`, `2b` or `8b` (setting `translation_model`).
    public var name: String
    /// `pfnet/plamo-3-translate-2b-GGUF`
    public var repository: String
    /// The Hugging Face commit the file is fetched from.
    public var revision: String
    /// The file's name in the repository.
    public var remoteFileName: String
    public var sizeBytes: Int64
    public var sha256: String

    public init(name: String, repository: String, revision: String, remoteFileName: String, sizeBytes: Int64,
                sha256: String) {
        self.name = name
        self.repository = repository
        self.revision = revision
        self.remoteFileName = remoteFileName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    /// `https://huggingface.co/<repo>/resolve/<revision>/<file>`: the pinned revision, never `main`.
    public var url: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remoteFileName)")!
    }

    /// The local name carries the revision's first 8 characters, so a catalog update to a new revision never
    /// counts an older file of the same size as installed.
    public var fileName: String {
        let stem = remoteFileName.hasSuffix(".gguf") ? String(remoteFileName.dropLast(5)) : remoteFileName
        return "\(stem)-\(revision.prefix(8)).gguf"
    }

    /// 「PLaMo 3 Translate 2B」
    public var displayName: String { "PLaMo 3 Translate \(name.uppercased())" }

    /// The model page (shown next to the license).
    public var pageURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
}

public enum TranslationModelCatalog {
    /// Values read from `https://huggingface.co/api/models/pfnet/<repo>` (`sha`) and `…/tree/main` (`size`,
    /// `lfs.oid`) on 2026-11-14; they match the files the research spike downloaded.
    public static let all: [TranslationModel] = [
        TranslationModel(name: "0.8b", repository: "pfnet/plamo-3-translate-0.8b-GGUF",
                         revision: "1cf96ae02133958a20074bfdfab76517bb737d00",
                         remoteFileName: "plamo-3-translate-0.8b-Q4_K_M.gguf", sizeBytes: 573_126_848,
                         sha256: "70891ec70dc7ab4205745a38307867c2881b99239f20327927633abfe4bc9ec6"),
        TranslationModel(name: "2b", repository: "pfnet/plamo-3-translate-2b-GGUF",
                         revision: "4f672106b847200bfdc0f6af6c321cd94eba1aed",
                         remoteFileName: "plamo-3-translate-2b-Q4_K_M.gguf", sizeBytes: 1_807_203_040,
                         sha256: "1ffd9073afcc70e35ccc942428aa2b73d7aa2b9ea779bf504b775369e0276c13"),
        TranslationModel(name: "8b", repository: "pfnet/plamo-3-translate-8b-GGUF",
                         revision: "c67efa4eefdc14d3c97bf8f4f35ee58e2ecd2f42",
                         remoteFileName: "plamo-3-translate-8b-Q4_K_M.gguf", sizeBytes: 5_280_445_728,
                         sha256: "94e5d3f91b421f7c8900ddaac27b11a19f7441426c954bbb25a2fd60a1640187"),
    ]

    public static func model(named name: String) -> TranslationModel? { all.first { $0.name == name } }
}

/// The translation models' manager: `models/translation/` under the app's data directory.
public typealias TranslationModelManager = ModelFileManager<TranslationModel>

extension AppPaths {
    public var translationModelsDirectory: URL {
        modelsDirectory.appending(path: "translation", directoryHint: .isDirectory)
    }
}

extension ModelFileManager where Model == TranslationModel {
    public init(paths: AppPaths, downloader: any ModelDownloading = URLSessionModelDownloader()) {
        self.init(directory: paths.translationModelsDirectory, catalog: TranslationModelCatalog.all,
                  downloader: downloader)
    }
}

/// What this Mac may use (spec 1). Decided from `MachineProfile`, never from `#if arch`.
public enum TranslationModelPolicy {
    /// 16 GB: the line for the 2B default and for 8B at all.
    public static let largeMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    /// Apple Silicon with 16 GB or more → 2B; otherwise (Intel, 8 GB machines) → 0.8B.
    public static func defaultModel(for profile: MachineProfile) -> TranslationModel {
        let name = profile.kind == .appleSilicon && profile.physicalMemory >= largeMemoryBytes ? "2b" : "0.8b"
        return TranslationModelCatalog.model(named: name)!
    }

    /// Why `model` cannot be picked on this Mac, or nil when it can (8B needs 16 GB).
    public static func unavailableReason(_ model: TranslationModel, profile: MachineProfile) -> String? {
        guard model.name == "8b", profile.physicalMemory < largeMemoryBytes else { return nil }
        return "メモリが 16 GB 未満の Mac では使えません"
    }

    /// Why `mode` cannot be picked on this Mac, or nil when it can (during-recording needs Apple Silicon).
    public static func unavailableReason(_ mode: TranslationMode, profile: MachineProfile) -> String? {
        guard mode == .duringRecording, profile.kind != .appleSilicon else { return nil }
        return "Intel の Mac では録音中の翻訳は使えません（文字起こしが遅れるため）"
    }

    /// The model the setting means on this Mac: the saved one when it exists and is allowed, else the default.
    public static func resolveModel(setting: String?, profile: MachineProfile) -> TranslationModel {
        if let setting, let model = TranslationModelCatalog.model(named: setting),
           unavailableReason(model, profile: profile) == nil {
            return model
        }
        return defaultModel(for: profile)
    }

    /// The mode the setting means on this Mac: during-recording falls back to after-recording on Intel.
    public static func effectiveMode(_ mode: TranslationMode, profile: MachineProfile) -> TranslationMode {
        unavailableReason(mode, profile: profile) == nil ? mode : .afterRecording
    }
}
