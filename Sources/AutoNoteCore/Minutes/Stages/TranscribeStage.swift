import Foundation
import os

/// Runs plan 04's final transcription; when it fails, falls back to the live transcript (spec §6.4).
/// Re-running the final pass later is plan 06's `rerun(id, from: "transcribe")`.
public struct TranscribeStage: QueueStage {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "TranscribeStage")

    public let name = StageName.transcribe
    private let runner: FinalTranscriptionRunner
    private let services: SharedVaultServices

    public init(runner: FinalTranscriptionRunner, services: SharedVaultServices = .standard) {
        self.runner = runner; self.services = services
    }

    public func run(_ job: inout Job, context: StageContext) async throws {
        let id = job.meeting
        let manifest = try await context.manifests.update(id) { $0.status = .transcribing }
        let dictionary = try await loadDictionary(context)

        let engine: String
        do {
            let result = try await runner.run(manifest: manifest, dictionary: dictionary,
                                              fillerRemoval: context.settings.fillerRemoval,
                                              progress: context.reportProgress)
            engine = result.final.engine
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = String(describing: type(of: error))
            guard let live = readLive(id, context.paths), !live.utterances.isEmpty else {
                Self.logger.error("\(id.rawValue, privacy: .public): final transcription failed (\(failure, privacy: .public)), no live transcript")
                try await context.manifests.update(id) { $0.status = .failed }
                throw StageError.failed(reason: "final_transcription_failed: \(failure)")
            }
            Self.logger.notice("\(id.rawValue, privacy: .public): final transcription failed (\(failure, privacy: .public)), using live transcript")
            engine = Transcript.fallbackEngineLabel(live: live.engine)
            try writeFallback(live, engine: engine, dictionary: dictionary,
                              fillerRemoval: context.settings.fillerRemoval, id: id, paths: context.paths)
        }

        job.transcriptEngine = engine
        try await context.manifests.update(id) { $0.status = .transcribed }
    }

    private func loadDictionary(_ context: StageContext) async throws -> DictionaryFile {
        let store = services.configStore(outputFolder: context.settings.outputFolder.map { URL(filePath: $0) },
                                         paths: context.paths)
        guard let data = try await store.read(.dictionary) else { return .default }
        return DictionaryFile.parse(String(decoding: data, as: UTF8.self)).dictionary
    }

    private func readLive(_ id: MeetingID, _ paths: AppPaths) -> Transcript? {
        guard let data = try? Data(contentsOf: paths.transcriptFile(id, .live)) else { return nil }
        return try? AutoNoteJSON.decoder().decode(Transcript.self, from: data)
    }

    /// Same order as `TranscriptFinalizer` (replace, then fillers), but no echo de-duplication:
    /// `live.json` carries no track information to de-duplicate against.
    private func writeFallback(_ live: Transcript, engine: String, dictionary: DictionaryFile, fillerRemoval: Bool,
                               id: MeetingID, paths: AppPaths) throws {
        var finalUtterances = Replacer(dictionary.replacements).apply(live.utterances)
        if fillerRemoval { finalUtterances = FillerRemover(fillers: dictionary.fillers).clean(finalUtterances) }
        let raw = Transcript(utterances: live.utterances, engine: engine, language: live.language)
        let final = Transcript(utterances: finalUtterances, engine: engine, language: live.language)
        let encoder = AutoNoteJSON.encoder()
        let rawData = try encoder.encode(raw)
        let finalData = try encoder.encode(final)
        try FileManager.default.createDirectory(at: paths.transcriptsDirectory(id), withIntermediateDirectories: true)
        try rawData.write(to: paths.transcriptFile(id, .raw), options: .atomic)
        try finalData.write(to: paths.transcriptFile(id, .final), options: .atomic)
    }
}
