import Foundation
import os

/// Generates `minutes.json` from `final.json`. A summarizer failure is recorded in `job.summaryFailure` and the
/// stage still succeeds, so `write_vault` writes a transcript-only note (spec §8.4).
public struct SummarizeStage: QueueStage {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "SummarizeStage")

    public let name = StageName.summarize
    private let summarizer: @Sendable (Settings, AppPaths) async throws -> any Summarizer
    private let services: SharedVaultServices

    public init(summarizer: @escaping @Sendable (Settings, AppPaths) async throws -> any Summarizer = SummarizerFactory.make,
                services: SharedVaultServices = .standard) {
        self.summarizer = summarizer; self.services = services
    }

    public func run(_ job: inout Job, context: StageContext) async throws {
        let id = job.meeting
        guard let data = try? Data(contentsOf: context.paths.transcriptFile(id, .final)),
              let final = try? AutoNoteJSON.decoder().decode(Transcript.self, from: data) else {
            Self.logger.error("\(id.rawValue, privacy: .public): final transcript missing or unreadable")
            throw StageError.failed(reason: "final_transcript_missing")
        }
        let manifest = try await context.manifests.update(id) { $0.status = .generating }
        let store = services.configStore(outputFolder: context.settings.outputFolder.map { URL(filePath: $0) },
                                         paths: context.paths)
        let input = SummaryInput(instructions: try await instructions(store),
                                 terms: try await dictionary(store).terms,
                                 bookmarks: manifest.bookmarks, transcript: final, language: manifest.language)

        let minutes: MinutesOutput
        do {
            minutes = try await summarizer(context.settings, context.paths).summarize(input)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let (kind, message) = Self.classify(error)
            Self.logger.notice("\(id.rawValue, privacy: .public): summarize failed (\(kind.rawValue, privacy: .public))")
            job.summaryFailure = SummaryFailureKind.encode(kind, message: message)
            return
        }

        try writeAtomically(AutoNoteJSON.encoder().encode(minutes), to: context.paths.minutesFile(id))
        job.summaryFailure = nil
        Self.logger.info("\(id.rawValue, privacy: .public): minutes generated")
    }

    private func instructions(_ store: PortableConfigStore) async throws -> String {
        guard let data = try await store.read(.prompt) else { return DefaultPrompt.instructions }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DefaultPrompt.instructions : text
    }

    private func dictionary(_ store: PortableConfigStore) async throws -> DictionaryFile {
        guard let data = try await store.read(.dictionary) else { return .default }
        return DictionaryFile.parse(String(decoding: data, as: UTF8.self)).dictionary
    }

    /// One-to-one with `SummarizerError`; anything else is `.other`.
    static func classify(_ error: any Error) -> (SummaryFailureKind, String) {
        guard let error = error as? SummarizerError else { return (.other, String(describing: type(of: error))) }
        switch error {
        case .claudeNotFound(let path): return (.claudeNotFound, path)
        case .notLoggedIn: return (.notLoggedIn, "")
        case .rateLimited(let message): return (.rateLimited, message)
        case .contextExceeded(let message): return (.contextExceeded, message)
        case .timedOut: return (.timedOut, "")
        case .invalidOutput(let message): return (.invalidOutput, message)
        case .failed(let exitCode, let message): return (.other, "exit \(exitCode): \(message)")
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: "minutes.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
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
}
