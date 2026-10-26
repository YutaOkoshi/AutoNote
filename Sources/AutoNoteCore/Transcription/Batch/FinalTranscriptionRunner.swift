import Foundation
import Synchronization

public struct FinalTranscriptResult: Sendable {
    public var raw: Transcript
    public var final: Transcript
    public var rawURL: URL
    public var finalURL: URL

    public init(raw: Transcript, final: Transcript, rawURL: URL, finalURL: URL) {
        self.raw = raw; self.final = final; self.rawURL = rawURL; self.finalURL = finalURL
    }
}

/// The batch pass after recording: merges each track's segments, transcribes the merged files one at a
/// time (mic first, then system; 要件書 §13), and writes `raw.json` / `final.json`.
public struct FinalTranscriptionRunner: Sendable {
    private let transcriber: any BatchTranscriber
    private let engineName: String
    private let paths: AppPaths
    private let gate: BatchGate

    public init(transcriber: any BatchTranscriber, engineName: String, paths: AppPaths, gate: BatchGate) {
        self.transcriber = transcriber; self.engineName = engineName; self.paths = paths; self.gate = gate
    }

    public func run(manifest: Manifest, dictionary: DictionaryFile, fillerRemoval: Bool,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> FinalTranscriptResult {
        let meetingDirectory = paths.meetingDirectory(manifest.id)
        var files: [TrackFile] = []
        for track in [Track.mic, .system] {
            do {
                files += try SegmentMerger.merge(manifest, track: track, meetingDirectory: meetingDirectory)
            } catch {
                throw TranscriptionError.trackFailed(track, String(describing: error))
            }
        }
        guard !files.isEmpty else { throw TranscriptionError.noTracks }

        let weights = try durationWeights(files, meetingDirectory: meetingDirectory)
        let reporter = MonotonicProgress(progress)
        var parts: [TrackTranscription] = []
        var done = 0.0
        for (file, weight) in zip(files, weights) {
            await gate.waitIfPaused()
            try Task.checkCancellation()
            let base = done
            do {
                let utterances = try await transcriber.transcribe(
                    file: meetingDirectory.appending(path: file.relativePath), language: manifest.language,
                    hints: dictionary.terms,
                    progress: { reporter.report(base + min(max($0, 0), 1) * weight) })
                parts.append(TrackTranscription(file: file, utterances: utterances))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscriptionError.trackFailed(file.track, String(describing: error))
            }
            done += weight
            reporter.report(done)
        }

        let (raw, final) = TranscriptFinalizer(dictionary: dictionary, fillerRemoval: fillerRemoval)
            .finalize(parts, source: manifest.source, engine: engineName, language: manifest.language)
        let rawURL = paths.transcriptFile(manifest.id, .raw)
        let finalURL = paths.transcriptFile(manifest.id, .final)
        let encoder = AutoNoteJSON.encoder()
        let rawData = try encoder.encode(raw)
        let finalData = try encoder.encode(final)
        try FileManager.default.createDirectory(at: paths.transcriptsDirectory(manifest.id),
                                                withIntermediateDirectories: true)
        try rawData.write(to: rawURL, options: .atomic)
        try finalData.write(to: finalURL, options: .atomic)
        reporter.report(1)
        return FinalTranscriptResult(raw: raw, final: final, rawURL: rawURL, finalURL: finalURL)
    }

    /// Each file's share of the whole by length; equal shares when no length is known.
    private func durationWeights(_ files: [TrackFile], meetingDirectory: URL) throws -> [Double] {
        let durations = try files.map { file in
            try file.durationSeconds ?? WAVFile.info(meetingDirectory.appending(path: file.relativePath)).durationSeconds
        }
        let total = durations.reduce(0, +)
        guard total > 0 else { return files.map { _ in 1 / Double(files.count) } }
        return durations.map { $0 / total }
    }
}

/// Forwards progress values, never going backwards.
private final class MonotonicProgress: Sendable {
    private let latest = Mutex(0.0)
    private let sink: @Sendable (Double) -> Void

    init(_ sink: @Sendable @escaping (Double) -> Void) { self.sink = sink }

    func report(_ value: Double) {
        let next = latest.withLock { latest -> Double in
            latest = max(latest, min(value, 1))
            return latest
        }
        sink(next)
    }
}
