import Foundation

public enum SegmentMergerError: Error, Equatable, Sendable {
    case missingFile(String)
}

/// Joins the time-contiguous WAV segments of one track into `merged/<track>-<n>.wav`.
/// Gaps (pauses) are never filled with silence: a gap starts a new output file.
public enum SegmentMerger {
    private static let sampleRate = 16_000

    public static func merge(_ manifest: Manifest, track: Track, meetingDirectory: URL) throws -> [TrackFile] {
        let fm = FileManager.default
        let segments = manifest.tracks.enumerated().filter { $0.element.track == track }
            .sorted { ($0.element.startOffset.seconds, $0.offset) < ($1.element.startOffset.seconds, $1.offset) }
            .map(\.element)
        guard !segments.isEmpty else { return [] }

        // Group into contiguous runs, reading lengths where the manifest has none.
        var runs: [[(file: TrackFile, url: URL)]] = []
        var prevEnd = 0.0
        for seg in segments {
            let url = meetingDirectory.appending(path: seg.relativePath)
            guard fm.fileExists(atPath: url.path) else { throw SegmentMergerError.missingFile(seg.relativePath) }
            let duration = try seg.durationSeconds ?? WAVFile.info(url).durationSeconds
            if let last = runs.last, !last.isEmpty,
               abs(seg.startOffset.seconds - prevEnd) <= TimelineAligner.tolerance {
                runs[runs.count - 1].append((seg, url))
            } else {
                runs.append([(seg, url)])
            }
            prevEnd = seg.startOffset.seconds + duration
        }

        let outDir = meetingDirectory.appending(path: "merged")
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        var result: [TrackFile] = []
        for (n, run) in runs.enumerated() {
            let relative = "merged/\(track.rawValue)-\(n).wav"
            let outURL = meetingDirectory.appending(path: relative)
            fm.createFile(atPath: outURL.path, contents: nil) // truncates an existing file
            let handle = try FileHandle(forWritingTo: outURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: WAVFile.header(sampleRate: sampleRate, channels: 1, bitsPerSample: 16, dataBytes: 0))
            var totalSamples = 0
            for item in run {
                let samples = try WAVFile.readSamples(item.url)
                totalSamples += samples.count
                try handle.write(contentsOf: samples.withUnsafeBytes { Data($0) })
            }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAVFile.header(sampleRate: sampleRate, channels: 1, bitsPerSample: 16,
                                                        dataBytes: totalSamples * 2))
            result.append(TrackFile(track: track, relativePath: relative, startOffset: run[0].file.startOffset,
                                    durationSeconds: Double(totalSamples) / Double(sampleRate)))
        }
        return result
    }
}
