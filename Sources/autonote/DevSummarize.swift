import AutoNoteCore
import AutoNoteTestSupport
import Foundation

/// `autonote dev summarize` — runs the whole post-processing queue (transcribe, summarize, write_vault,
/// update_index) on one fictional meeting with fake transcription and summarization (or the real `claude` with
/// `--claude`). Prints one JSON line `{"meeting_id","file","status"}`. Exit codes: 0 done, 1 job not done / error,
/// 2 usage.
enum DevSummarize {
    static let usage = DevSummarizeArguments.usage

    private struct Result: Encodable {
        var meetingId: String
        var file: String
        var status: String
    }

    static func run(_ args: [String]) async -> Int32 {
        let options: DevSummarizeArguments
        do { options = try DevSummarizeArguments.parse(args) } catch {
            return DevCommands.usageError(usage)
        }
        do {
            return try await execute(options)
        } catch {
            DevCommands.printError("error: \(error)")
            return 1
        }
    }

    private static func execute(_ o: DevSummarizeArguments) async throws -> Int32 {
        let fm = FileManager.default
        let paths = AppPaths(root: o.out.appending(path: "app", directoryHint: .isDirectory))
        let vault = o.out.appending(path: "vault", directoryHint: .isDirectory)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)

        var settings = Settings()
        settings.outputFolder = vault.path
        try await SettingsStore(paths: paths).save(settings)

        let transcript = try AutoNoteJSON.decoder().decode(Transcript.self, from: Data(contentsOf: o.transcript))

        let started = ISO8601DateFormatter().date(from: "2026-10-24T05:00:00Z") ?? Date(timeIntervalSince1970: 1_792_818_000)
        let id = MeetingID(rawValue: "20261024-0500-dev0")
        let tracksDir = paths.tracksDirectory(id)
        try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try PCMAudio.writeWAV(Array(repeating: 0, count: 16_000), to: tracksDir.appending(path: "mic-000.wav"))
        let manifest = Manifest(
            id: id, title: nil, startedAt: started, endedAt: started.addingTimeInterval(1), source: .live, device: nil,
            language: transcript.language, tracks: [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav",
                                                              startOffset: TimelineTime(seconds: 0), durationSeconds: 1)],
            pauses: [], bookmarks: [], status: .recorded, silenceWarning: false, autonoteVersion: AutoNoteVersion.current)
        try await ManifestStore(paths: paths).save(manifest)

        let gate = BatchGate()
        let runner = FinalTranscriptionRunner(
            transcriber: FakeBatchTranscriber(results: ["mic-0.wav": transcript.utterances]),
            engineName: transcript.engine, paths: paths, gate: gate)
        let summarizer: @Sendable (Settings, AppPaths) async throws -> any Summarizer
        if o.useClaude {
            summarizer = SummarizerFactory.make
        } else if o.failSummary {
            let fake = FakeSummarizer(result: .failure(FakeError(message: "dev")))
            summarizer = { _, _ in fake }
        } else if let minutesURL = o.minutes {
            let minutes = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(contentsOf: minutesURL))
            let fake = FakeSummarizer(result: .success(minutes))
            summarizer = { _, _ in fake }
        } else {
            return DevCommands.usageError(usage)
        }

        let stages = PostProcessingPipeline.standardStages(runner: runner, summarizer: summarizer, timeZone: .current,
                                                           services: .standard)
        let queue = PostProcessingQueue(paths: paths, stages: stages, activity: NeverRecording(), gate: gate)
        await queue.enqueue(id)
        await queue.runUntilIdle()

        let job = try await JobStore(paths: paths).load(id)
        guard let job, job.state == .done else {
            DevCommands.printError("error: job not done (\(job?.state.rawValue ?? "missing")): \(job?.lastError ?? "")")
            return 1
        }
        guard let file = meetingFile(in: vault) else {
            DevCommands.printError("error: no meeting file in the vault")
            return 1
        }
        let status = try await ManifestStore(paths: paths).load(id).status
        let line = try AutoNoteJSON.compactEncoder().encode(Result(meetingId: id.rawValue, file: file, status: status.rawValue))
        FileHandle.standardOutput.write(line + Data("\n".utf8))
        return 0
    }

    /// The meeting note (any `.md` other than `_index.md`), relative to the vault.
    private static func meetingFile(in vault: URL) -> String? {
        guard let walker = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil) else { return nil }
        let base = vault.standardizedFileURL.path + "/"
        for case let url as URL in walker where url.pathExtension == "md" && url.lastPathComponent != "_index.md" {
            return String(url.standardizedFileURL.path.dropFirst(base.count))
        }
        return nil
    }
}
