import Foundation
import os

/// Writes the meeting note into the Vault through the shared `VaultWriter` (spec §8.4, §9.4, §9.5).
/// A note without minutes is written as `transcript_only`; an edited note waits for confirmation; an
/// unavailable output folder retries every five minutes (the content stays safe in the app's own area).
public struct WriteVaultStage: QueueStage {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "WriteVaultStage")

    public let name = StageName.writeVault
    public static let retryInterval: TimeInterval = 300
    private let timeZone: TimeZone
    private let services: SharedVaultServices

    public init(timeZone: TimeZone = .current, services: SharedVaultServices = .standard) {
        self.timeZone = timeZone; self.services = services
    }

    public func run(_ job: inout Job, context: StageContext) async throws {
        let id = job.meeting
        guard let folderPath = context.settings.outputFolder else {
            Self.logger.notice("\(id.rawValue, privacy: .public): output folder not set, retry later")
            throw StageError.retry(after: Self.retryInterval, reason: "output_folder_missing")
        }
        let minutesURL = context.paths.minutesFile(id)

        // A failed regeneration must not overwrite the existing minutes with a transcript-only note. The
        // previous minutes stay the state of record, so undo SummarizeStage's `.generating`.
        if job.summaryFailure != nil, FileManager.default.fileExists(atPath: minutesURL.path) {
            _ = try await context.manifests.update(id) { $0.status = .minutesGenerated }
            for stage in [StageName.updateIndex, StageName.automations] where !job.completedStages.contains(stage) {
                job.completedStages.append(stage)
            }
            Self.logger.info("\(id.rawValue, privacy: .public): regeneration failed, keeping existing note")
            return
        }

        guard let data = try? Data(contentsOf: context.paths.transcriptFile(id, .final)),
              let final = try? AutoNoteJSON.decoder().decode(Transcript.self, from: data) else {
            Self.logger.error("\(id.rawValue, privacy: .public): final transcript missing or unreadable")
            throw StageError.failed(reason: "final_transcript_missing")
        }

        let minutes = decodeMinutes(at: minutesURL, id: id)
        let status = Self.resultingStatus(minutesExist: minutes != nil, job: job)
        var manifest = try await context.manifests.load(id)
        manifest.status = status
        let outputFolder = URL(filePath: folderPath, directoryHint: .isDirectory)
        let store = services.configStore(outputFolder: outputFolder, paths: context.paths)
        let writer = services.vaultWriter(outputFolder: outputFolder, paths: context.paths, now: context.now)

        // Every Vault-folder I/O (frontmatter read and the write) maps to a retry whose reason carries no path.
        let outcome: VaultWriteOutcome
        do {
            let frontmatterText = try await store.read(.frontmatter).map { String(decoding: $0, as: UTF8.self) }
                ?? FrontmatterTemplate.defaultText
            let document = MeetingDocument(manifest: manifest, transcript: final, minutes: minutes,
                                           frontmatter: FrontmatterTemplate(text: frontmatterText),
                                           appVersion: AutoNoteVersion.current, timeZone: timeZone)
            outcome = try await writer.write(document, policy: job.overwriteApproved ? .force : .ifUnchanged)
        } catch is CancellationError {
            throw CancellationError()
        } catch VaultError.outputFolderUnavailable {
            Self.logger.notice("\(id.rawValue, privacy: .public): output folder unavailable, retry later")
            throw StageError.retry(after: Self.retryInterval, reason: "output_folder_unavailable")
        } catch {
            let kind = String(describing: type(of: error))
            Self.logger.error("\(id.rawValue, privacy: .public): vault I/O failed (\(kind, privacy: .public))")
            throw StageError.retry(after: Self.retryInterval, reason: kind)
        }

        switch outcome {
        case .written:
            _ = try await context.manifests.update(id) { $0.status = status }
            job.overwriteApproved = false
            Self.logger.info("\(id.rawValue, privacy: .public): note written (\(status.rawValue, privacy: .public))")
        case .conflict(let url):
            Self.logger.notice("\(id.rawValue, privacy: .public): note edited, awaiting confirmation")
            throw StageError.awaitingConfirmation(path: Self.relativePath(of: url, in: outputFolder))
        }
    }

    /// The status a written note carries: minutes only count when they exist and the last summarize did not fail.
    static func resultingStatus(minutesExist: Bool, job: Job) -> MeetingStatus {
        (minutesExist && job.summaryFailure == nil) ? .minutesGenerated : .transcriptOnly
    }

    /// `nil` when absent; an existing file that cannot be decoded is logged and treated as absent (transcript-only).
    private func decodeMinutes(at url: URL, id: MeetingID) -> MinutesOutput? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let minutes = try? AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(contentsOf: url)) else {
            Self.logger.error("\(id.rawValue, privacy: .public): minutes_unreadable, falling back to transcript_only")
            return nil
        }
        return minutes
    }

    /// `file` relative to `folder` with `/` separators; both are resolved so `/var` and `/private/var` match.
    static func relativePath(of file: URL, in folder: URL) -> String {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.lastPathComponent
    }
}
