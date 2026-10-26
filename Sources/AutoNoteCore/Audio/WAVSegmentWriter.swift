import Foundation

public enum SegmentChange: Equatable, Sendable {
    case opened(TrackFile)
    case closed(TrackFile)
}

public enum WAVSegmentWriterError: Error, Equatable, Sendable {
    case notOpen
}

/// Writes one track as 16 kHz mono Int16 WAV segments (default 5 minutes each), keeping the meeting timeline
/// aligned by filling gaps with silence. Samples stream through an open `FileHandle`; nothing is buffered whole.
public struct WAVSegmentWriter {
    public static let segmentSeconds: Double = 300

    private static let sampleRate = Int(AudioChunk.sampleRate)

    private let track: Track
    private let meetingDirectory: URL
    private let segmentSamples: Int
    private var nextIndex = 0
    private var aligner: TimelineAligner?
    private var segment: Segment?
    private var sessionSamples = 0
    private let oneSecondOfSilence = Data(count: Int(AudioChunk.sampleRate) * 2)

    private struct Segment {
        var handle: FileHandle
        var url: URL
        var file: TrackFile
        var samples = 0
    }

    private var sessionStartTime = TimelineTime(seconds: 0)

    public init(track: Track, meetingDirectory: URL, segmentSeconds: Double = WAVSegmentWriter.segmentSeconds) {
        self.track = track
        self.meetingDirectory = meetingDirectory
        self.segmentSamples = max(1, Int((segmentSeconds * AudioChunk.sampleRate).rounded()))
    }

    public var isOpen: Bool { segment != nil }

    public mutating func open(at start: TimelineTime) throws -> [SegmentChange] {
        var changes: [SegmentChange] = []
        if segment != nil { changes += try finishSegment() }
        aligner = TimelineAligner(start: start)
        sessionStartTime = start
        sessionSamples = 0
        changes.append(.opened(try startSegment(at: start)))
        return changes
    }

    public mutating func write(_ chunk: AudioChunk) throws -> [SegmentChange] {
        guard segment != nil, var a = aligner else { throw WAVSegmentWriterError.notOpen }
        let placement = a.place(chunk)
        aligner = a
        var changes: [SegmentChange] = []
        try appendSilence(placement.silenceBefore, changes: &changes)
        try appendSamples(placement.samples, changes: &changes)
        return changes
    }

    public mutating func close(at end: TimelineTime) throws -> [SegmentChange] {
        guard segment != nil, var a = aligner else { return [] }
        let pad = a.padding(to: end)
        aligner = a
        var changes: [SegmentChange] = []
        try appendSilence(pad, changes: &changes)
        changes += try finishSegment()
        aligner = nil
        return changes
    }

    // MARK: - Private

    /// Rolls to a new segment when the current one is full and more data is waiting.
    private mutating func rollIfFull(changes: inout [SegmentChange]) throws {
        guard let s = segment, s.samples >= segmentSamples else { return }
        changes += try finishSegment()
        let offset = TimelineTime(seconds: sessionStartTime.seconds + Double(sessionSamples) / AudioChunk.sampleRate)
        changes.append(.opened(try startSegment(at: offset)))
    }

    private mutating func appendSilence(_ count: Int, changes: inout [SegmentChange]) throws {
        var remaining = count
        while remaining > 0 {
            try rollIfFull(changes: &changes)
            let n = min(remaining, segmentSamples - segment!.samples, Self.sampleRate)
            try segment!.handle.write(contentsOf: oneSecondOfSilence.prefix(n * 2))
            account(n)
            remaining -= n
        }
    }

    private mutating func appendSamples(_ samples: ArraySlice<Int16>, changes: inout [SegmentChange]) throws {
        var rest = samples
        while !rest.isEmpty {
            try rollIfFull(changes: &changes)
            let n = min(rest.count, segmentSamples - segment!.samples)
            let piece = rest.prefix(n)
            let data = piece.withUnsafeBytes { Data($0) }   // native little-endian on arm64 / x86_64
            try segment!.handle.write(contentsOf: data)
            account(n)
            rest = rest.dropFirst(n)
        }
    }

    private mutating func account(_ n: Int) {
        segment!.samples += n
        sessionSamples += n
    }

    private mutating func startSegment(at offset: TimelineTime) throws -> TrackFile {
        let relative = "tracks/\(track.rawValue)-\(String(format: "%03d", nextIndex)).wav"
        let url = meetingDirectory.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WAVFile.header(sampleRate: Self.sampleRate, channels: 1, bitsPerSample: 16, dataBytes: 0).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        nextIndex += 1
        let file = TrackFile(track: track, relativePath: relative, startOffset: offset)
        segment = Segment(handle: handle, url: url, file: file)
        return file
    }

    private mutating func finishSegment() throws -> [SegmentChange] {
        guard let s = segment else { return [] }
        segment = nil
        defer { try? s.handle.close() }
        try s.handle.seek(toOffset: 0)
        try s.handle.write(contentsOf: WAVFile.header(sampleRate: Self.sampleRate, channels: 1, bitsPerSample: 16,
                                                      dataBytes: s.samples * 2))
        var file = s.file
        file.durationSeconds = Double(s.samples) / AudioChunk.sampleRate
        return [.closed(file)]
    }
}
