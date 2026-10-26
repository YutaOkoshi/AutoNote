import Foundation
import AVFoundation

public enum ImportError: Error, Equatable, Sendable {
    case unsupportedFormat(String)
    case noAudioTrack
    case unreadable(String)
}

/// Imports an audio file (wav / m4a / mp3 / mp4) as a meeting whose single mic track is a 16 kHz mono Int16 WAV.
public struct AudioImporter: Sendable {
    public static let supportedExtensions: Set<String> = ["wav", "m4a", "mp3", "mp4"]
    public static let importDevice = DeviceRef(name: "import", uid: "import", transport: "import")

    private static let sampleRate = Int(AudioChunk.sampleRate)
    private static let relativePath = "tracks/import-000.wav"

    private let paths: AppPaths
    private let manifests: ManifestStore
    private let timeZone: TimeZone

    public init(paths: AppPaths, manifests: ManifestStore, timeZone: TimeZone = .current) {
        self.paths = paths
        self.manifests = manifests
        self.timeZone = timeZone
    }

    public func importFile(_ url: URL, startedAt: Date? = nil, language: Language,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Manifest {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw ImportError.unsupportedFormat(ext) }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImportError.unreadable("cannot read \(url.lastPathComponent)")
        }

        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack
        let assetSeconds: Double
        do {
            guard let first = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ImportError.noAudioTrack
            }
            track = first
            assetSeconds = try await asset.load(.duration).seconds
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }

        // Manifest dates are stored at millisecond precision; truncate so the saved manifest equals the returned one.
        let resolved = startedAt ?? Self.fileDate(url)
        let start = resolved.truncatedToMilliseconds
        // Never reuse an existing meeting directory: failure cleanup deletes the whole directory.
        var id = MeetingID.make(start: start, timeZone: timeZone)
        while FileManager.default.fileExists(atPath: paths.meetingDirectory(id).path) {
            id = MeetingID.make(start: start, timeZone: timeZone)
        }
        let wavURL = paths.tracksDirectory(id).appending(path: "import-000.wav")

        do {
            try FileManager.default.createDirectory(at: wavURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Task.detached does not inherit cancellation, so forward it explicitly.
            let work = Task.detached(priority: .utility) {
                try Self.transcode(asset: asset, track: track, to: wavURL,
                                   assetSeconds: assetSeconds, progress: progress)
            }
            let samples = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            let seconds = Double(samples) / AudioChunk.sampleRate
            let manifest = Manifest(
                id: id, title: nil, startedAt: start, endedAt: start.addingTimeInterval(seconds).truncatedToMilliseconds,
                source: .imported, device: Self.importDevice, language: language,
                tracks: [TrackFile(track: .mic, relativePath: Self.relativePath,
                                   startOffset: TimelineTime(seconds: 0), durationSeconds: seconds)],
                pauses: [], bookmarks: [], status: .recorded, silenceWarning: false,
                autonoteVersion: AutoNoteVersion.current)
            try await manifests.save(manifest)
            progress(1.0)
            return manifest
        } catch {
            try? await manifests.delete(id)
            if error is CancellationError || error is ImportError { throw error }
            throw ImportError.unreadable(error.localizedDescription)
        }
    }

    // MARK: - Private

    private static func fileDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    /// Streams decoded 16 kHz mono Int16 PCM into `wavURL`; returns the number of samples written.
    private static func transcode(asset: AVURLAsset, track: AVAssetTrack, to wavURL: URL, assetSeconds: Double,
                                  progress: @Sendable (Double) -> Void) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportError.unreadable("unsupported audio track") }
        reader.add(output)
        guard reader.startReading() else {
            throw ImportError.unreadable(reader.error?.localizedDescription ?? "cannot start reading")
        }

        try WAVFile.header(sampleRate: sampleRate, channels: 1, bitsPerSample: 16, dataBytes: 0).write(to: wavURL)
        let handle = try FileHandle(forWritingTo: wavURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var bytesWritten = 0
        var lastProgress = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw ImportError.unreadable("decode failed (\(status))") }
                try handle.write(contentsOf: data)
                bytesWritten += length
            }
            if assetSeconds > 0, assetSeconds.isFinite {
                let p = min(0.999, max(lastProgress, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / assetSeconds))
                if p.isFinite, p > lastProgress { lastProgress = p; progress(p) }
            }
        }
        if reader.status != .completed {
            throw ImportError.unreadable(reader.error?.localizedDescription ?? "decode did not complete")
        }
        bytesWritten &= ~1
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVFile.header(sampleRate: sampleRate, channels: 1, bitsPerSample: 16,
                                                    dataBytes: bytesWritten))
        return bytesWritten / 2
    }
}
