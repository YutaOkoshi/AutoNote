import Foundation
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct RecordingReportTests {
    private func manifest() -> Manifest {
        var m = Samples.manifest
        m.status = .recorded
        m.tracks = [
            TrackFile(track: .system, relativePath: "tracks/system-000.wav", startOffset: TimelineTime(seconds: 0), durationSeconds: 310),
            TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: TimelineTime(seconds: 0), durationSeconds: 300),
            TrackFile(track: .mic, relativePath: "tracks/mic-001.wav", startOffset: TimelineTime(seconds: 300), durationSeconds: 10),
        ]
        return m
    }

    private func make(stats: [Track: TrackStatistics], events: [RecordingEvent] = []) throws -> RecordingReport {
        let dir = URL(filePath: "/nonexistent/meeting")
        return try RecordingReport.make(manifest: manifest(), manifestURL: dir.appending(path: "manifest.json"),
                                        meetingDirectory: dir, statistics: stats, events: events,
                                        micPermission: .authorized)
    }

    @Test func summarizesTracksAndEvents() throws {
        let id = Samples.manifest.id
        let report = try make(
            stats: [.mic: TrackStatistics(chunks: 31, samples: 1, peakDBFS: -12), .system: TrackStatistics(chunks: 31)],
            events: [.started(id), .sourceFailed(.system, message: "x"),
                     .silenceWarning(SilenceWarning(track: .mic, message: "m")), .stopped(manifest(), .manual)])
        #expect(report.tracks.map(\.track) == ["mic", "system"])
        #expect(report.tracks[0].files == 2)
        #expect(report.tracks[0].seconds == 310)
        #expect(report.tracks[0].chunks == 31)
        #expect(report.tracks[0].peakDbfs == -12)
        #expect(report.tracks[1].files == 1)
        #expect(report.events == ["started", "sourceFailed(system)", "silenceWarning(mic)", "stopped"])
        #expect(report.status == manifest().status.rawValue)
        #expect(report.manifest == "/nonexistent/meeting/manifest.json")
        #expect(report.micPermission == "authorized")
    }

    @Test func jsonUsesSnakeCaseAndNullForSilence() throws {
        let report = try make(stats: [.mic: TrackStatistics(), .system: TrackStatistics(chunks: 1, peakDBFS: -3)])
        let line = try report.jsonLine()
        #expect(!line.contains("\n"))
        #expect(line.contains("\"peak_dbfs\":null"))
        #expect(line.contains("\"meeting_id\":"))
        #expect(line.contains("\"mic_permission\":\"authorized\""))
        #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
    }

    @Test func readsDurationFromWAVWhenManifestHasNone() throws {
        let dir = try TemporaryDirectory.make()
        try FileManager.default.createDirectory(at: dir.appending(path: "tracks"), withIntermediateDirectories: true)
        let samples = 16_000  // 1 second of 16 kHz mono Int16
        var data = WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: samples * 2)
        data.append(Data(count: samples * 2))
        try data.write(to: dir.appending(path: "tracks/mic-000.wav"))
        var m = manifest()
        m.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: TimelineTime(seconds: 0))]
        let report = try RecordingReport.make(manifest: m, manifestURL: dir.appending(path: "manifest.json"),
                                              meetingDirectory: dir, statistics: [:], events: [],
                                              micPermission: .authorized)
        #expect(report.tracks[0].seconds == 1.0)
        #expect(report.tracks[0].chunks == 0)
        #expect(report.tracks[1].files == 0)
    }
}
