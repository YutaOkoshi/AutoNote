import Foundation

/// JSON summary of a finished recording, printed by `autonote dev record`.
public struct RecordingReport: Codable, Equatable, Sendable {
    public struct TrackReport: Codable, Equatable, Sendable {
        public var track: String
        public var files: Int
        public var seconds: Double
        public var chunks: Int
        public var peakDbfs: Double?

        public init(track: String, files: Int, seconds: Double, chunks: Int, peakDbfs: Double?) {
            self.track = track; self.files = files; self.seconds = seconds; self.chunks = chunks; self.peakDbfs = peakDbfs
        }

        private enum CodingKeys: String, CodingKey { case track, files, seconds, chunks, peakDbfs }

        /// Encodes `peakDbfs` explicitly so silence is `null` rather than a missing key.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(track, forKey: .track)
            try c.encode(files, forKey: .files)
            try c.encode(seconds, forKey: .seconds)
            try c.encode(chunks, forKey: .chunks)
            try c.encode(peakDbfs, forKey: .peakDbfs)
        }
    }

    public var meetingId: String
    public var manifest: String
    public var status: String
    public var micPermission: String
    public var tracks: [TrackReport]
    public var events: [String]

    public init(meetingId: String, manifest: String, status: String, micPermission: String,
                tracks: [TrackReport], events: [String]) {
        self.meetingId = meetingId; self.manifest = manifest; self.status = status
        self.micPermission = micPermission; self.tracks = tracks; self.events = events
    }

    public static func make(manifest: Manifest, manifestURL: URL, meetingDirectory: URL,
                            statistics: [Track: TrackStatistics], events: [RecordingEvent],
                            micPermission: MicrophonePermissionStatus) throws -> RecordingReport {
        var reports: [TrackReport] = []
        for track in [Track.mic, .system] {
            let files = manifest.tracks.filter { $0.track == track }
            var seconds = 0.0
            for file in files {
                if let d = file.durationSeconds {
                    seconds += d
                } else {
                    seconds += try WAVFile.info(meetingDirectory.appending(path: file.relativePath)).durationSeconds
                }
            }
            let stats = statistics[track]
            let peak = stats.map(\.peakDBFS)
            reports.append(TrackReport(track: track.rawValue, files: files.count, seconds: seconds,
                                       chunks: stats?.chunks ?? 0,
                                       peakDbfs: (peak?.isFinite ?? false) ? peak : nil))
        }
        return RecordingReport(meetingId: manifest.id.rawValue, manifest: manifestURL.path,
                               status: manifest.status.rawValue, micPermission: micPermission.rawValue,
                               tracks: reports, events: events.map(Self.name))
    }

    public func jsonLine() throws -> String {
        String(decoding: try AutoNoteJSON.compactEncoder().encode(self), as: UTF8.self)
    }

    private static func name(_ event: RecordingEvent) -> String {
        switch event {
        case .started: "started"
        case .paused: "paused"
        case .resumed: "resumed"
        case .bookmarked: "bookmarked"
        case .silenceWarning(let w): "silenceWarning(\(w.track.rawValue))"
        case .diskSpaceLow: "diskSpaceLow"
        case .sourceFailed(let track, _): "sourceFailed(\(track.rawValue))"
        case .microphoneDetached: "microphoneDetached"
        case .microphoneAttached: "microphoneAttached"
        case .stopped: "stopped"
        }
    }
}
