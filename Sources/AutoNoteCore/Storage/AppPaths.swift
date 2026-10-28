import Foundation

public enum TranscriptKind: String, Sendable {
    case live, raw, final
}

public struct AppPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/AutoNote`
    public static var standard: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return AppPaths(root: support.appending(path: "AutoNote", directoryHint: .isDirectory))
    }

    /// Uses `AUTONOTE_DATA_DIR` when present and non-empty, else `standard`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let dir = environment["AUTONOTE_DATA_DIR"], !dir.isEmpty {
            return AppPaths(root: URL(filePath: dir, directoryHint: .isDirectory))
        }
        return .standard
    }

    public var settingsFile: URL { root.appending(path: "settings.json") }
    public var automationsFile: URL { root.appending(path: "automations.json") }
    public var recordingsDirectory: URL { root.appending(path: "recordings", directoryHint: .isDirectory) }
    public var queueJobsDirectory: URL { root.appending(path: "queue/jobs", directoryHint: .isDirectory) }
    public var logsDirectory: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    public var logFile: URL { root.appending(path: "logs/autonote.log") }
    public var portableMirrorDirectory: URL { root.appending(path: "portable-mirror", directoryHint: .isDirectory) }
    public var vaultStateDirectory: URL { root.appending(path: "vault-state", directoryHint: .isDirectory) }
    public var modelsDirectory: URL { root.appending(path: "models", directoryHint: .isDirectory) }
    public var socketFile: URL { root.appending(path: "autonote.sock") }

    public func meetingDirectory(_ id: MeetingID) -> URL {
        recordingsDirectory.appending(path: id.rawValue, directoryHint: .isDirectory)
    }
    public func manifestFile(_ id: MeetingID) -> URL { meetingDirectory(id).appending(path: "manifest.json") }
    public func tracksDirectory(_ id: MeetingID) -> URL { meetingDirectory(id).appending(path: "tracks", directoryHint: .isDirectory) }
    public func transcriptsDirectory(_ id: MeetingID) -> URL {
        root.appending(path: "transcripts", directoryHint: .isDirectory).appending(path: id.rawValue, directoryHint: .isDirectory)
    }
    public func transcriptFile(_ id: MeetingID, _ kind: TranscriptKind) -> URL {
        transcriptsDirectory(id).appending(path: "\(kind.rawValue).json")
    }
    public func minutesFile(_ id: MeetingID) -> URL { transcriptsDirectory(id).appending(path: "minutes.json") }
    public func liveSummaryFile(_ id: MeetingID) -> URL { transcriptsDirectory(id).appending(path: "live-summary.json") }
    public func vaultStateFile(_ id: MeetingID) -> URL { vaultStateDirectory.appending(path: "\(id.rawValue).json") }

    public func createBaseDirectories() throws {
        for dir in [root, recordingsDirectory, queueJobsDirectory, logsDirectory,
                    portableMirrorDirectory, vaultStateDirectory, modelsDirectory,
                    root.appending(path: "transcripts", directoryHint: .isDirectory)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
