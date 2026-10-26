import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct SegmentMergerTests {
    private func record(_ spans: [(start: Double, seconds: Double, value: Int16)], track: Track = .mic,
                        in dir: URL) throws -> [TrackFile] {
        var w = WAVSegmentWriter(track: track, meetingDirectory: dir)
        var files: [TrackFile] = []
        for s in spans {
            var changes = try w.open(at: .init(seconds: s.start))
            changes += try w.write(AudioFixtures.tone(start: s.start, seconds: s.seconds, value: s.value, track: track))
            changes += try w.close(at: .init(seconds: s.start + s.seconds))
            for case .closed(let f) in changes { files.append(f) }
        }
        return files
    }

    private func manifest(_ tracks: [TrackFile]) -> Manifest {
        var m = Samples.manifest
        m.tracks = tracks
        return m
    }

    @Test func joinsContiguousSegments() throws {
        let dir = try TemporaryDirectory.make()
        let files = try record([(0, 300, 1000), (300, 10, 2000)], in: dir)
        #expect(files.count == 2)
        let merged = try SegmentMerger.merge(manifest(files), track: .mic, meetingDirectory: dir)
        #expect(merged == [TrackFile(track: .mic, relativePath: "merged/mic-0.wav", startOffset: .init(seconds: 0), durationSeconds: 310)])
        let out = try WAVFile.readSamples(dir.appending(path: "merged/mic-0.wav"))
        let expected = try files.flatMap { try WAVFile.readSamples(dir.appending(path: $0.relativePath)) }
        #expect(out == expected)
        #expect(try WAVFile.info(dir.appending(path: "merged/mic-0.wav")).durationSeconds == 310)
    }

    @Test func splitsAtPause() throws {
        let dir = try TemporaryDirectory.make()
        let files = try record([(0, 10, 1000), (20, 10, 2000)], in: dir)
        let merged = try SegmentMerger.merge(manifest(files), track: .mic, meetingDirectory: dir)
        #expect(merged == [
            TrackFile(track: .mic, relativePath: "merged/mic-0.wav", startOffset: .init(seconds: 0), durationSeconds: 10),
            TrackFile(track: .mic, relativePath: "merged/mic-1.wav", startOffset: .init(seconds: 20), durationSeconds: 10),
        ])
    }

    @Test func ignoresOtherTrackAndEmpty() throws {
        let dir = try TemporaryDirectory.make()
        let files = try record([(0, 2, 1000)], track: .system, in: dir)
        #expect(try SegmentMerger.merge(manifest(files), track: .mic, meetingDirectory: dir) == [])
        #expect(try SegmentMerger.merge(manifest([]), track: .mic, meetingDirectory: dir) == [])
    }

    @Test func readsMissingDurationFromFile() throws {
        let dir = try TemporaryDirectory.make()
        var files = try record([(0, 2, 1000), (2, 3, 2000)], in: dir)
        files[0].durationSeconds = nil
        let merged = try SegmentMerger.merge(manifest(files), track: .mic, meetingDirectory: dir)
        #expect(merged.count == 1 && merged[0].durationSeconds == 5)
    }

    @Test func missingFileThrows() throws {
        let dir = try TemporaryDirectory.make()
        let ghost = TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0), durationSeconds: 1)
        #expect(throws: SegmentMergerError.missingFile("tracks/mic-000.wav")) {
            try SegmentMerger.merge(manifest([ghost]), track: .mic, meetingDirectory: dir)
        }
    }
}
