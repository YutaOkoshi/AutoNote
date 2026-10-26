import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct WAVSegmentWriterTests {
    @Test func writes16kMono16bit() throws {
        let dir = try TemporaryDirectory.make()
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0)); _ = try w.write(AudioFixtures.tone(start: 0, seconds: 2))
        let closed = try w.close(at: .init(seconds: 2))
        #expect(closed == [.closed(TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0), durationSeconds: 2))])
        let info = try WAVFile.info(dir.appending(path: "tracks/mic-000.wav"))
        #expect(info.sampleRate == 16_000 && info.channels == 1 && info.bitsPerSample == 16 && info.durationSeconds == 2)
    }

    @Test func splitsEveryFiveMinutes() throws {
        let dir = try TemporaryDirectory.make()
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        var changes = try w.open(at: .init(seconds: 0))
        for i in 0..<301 { changes += try w.write(AudioFixtures.tone(start: Double(i), seconds: 1)) }
        changes += try w.close(at: .init(seconds: 301))
        #expect(changes == [
            .opened(TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0))),
            .closed(TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0), durationSeconds: 300)),
            .opened(TrackFile(track: .mic, relativePath: "tracks/mic-001.wav", startOffset: .init(seconds: 300))),
            .closed(TrackFile(track: .mic, relativePath: "tracks/mic-001.wav", startOffset: .init(seconds: 300), durationSeconds: 1)),
        ])
        #expect(try WAVFile.info(dir.appending(path: "tracks/mic-000.wav")).durationSeconds == 300)
    }

    @Test func chunkSpanningBoundaryIsSplit() throws {
        let dir = try TemporaryDirectory.make()
        var w = WAVSegmentWriter(track: .system, meetingDirectory: dir, segmentSeconds: 2)
        _ = try w.open(at: .init(seconds: 0))
        let changes = try w.write(AudioFixtures.tone(start: 0, seconds: 3, track: .system))
        #expect(changes.count == 2)
        _ = try w.close(at: .init(seconds: 3))
        #expect(try WAVFile.info(dir.appending(path: "tracks/system-000.wav")).durationSeconds == 2)
        #expect(try WAVFile.info(dir.appending(path: "tracks/system-001.wav")).durationSeconds == 1)
    }

    @Test func fillsGapWithSilenceAndPadsTail() throws {
        let dir = try TemporaryDirectory.make()
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0))
        _ = try w.write(AudioFixtures.tone(start: 0, seconds: 1))
        _ = try w.write(AudioFixtures.tone(start: 3, seconds: 1))
        _ = try w.close(at: .init(seconds: 6))
        let url = dir.appending(path: "tracks/mic-000.wav")
        #expect(try WAVFile.info(url).durationSeconds == 6)
        let s = try WAVFile.readSamples(url)
        #expect(s.count == 96_000)
        #expect(s[16_000..<48_000].allSatisfy { $0 == 0 })
        #expect(s[48_000..<64_000].allSatisfy { $0 == 1000 })
        #expect(s[64_000...].allSatisfy { $0 == 0 })
    }

    @Test func reopenAfterPauseStartsNewSegmentAtResumeTime() throws {
        let dir = try TemporaryDirectory.make()
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0))
        _ = try w.write(AudioFixtures.tone(start: 0, seconds: 10))
        _ = try w.close(at: .init(seconds: 10))
        #expect(!w.isOpen)
        _ = try w.open(at: .init(seconds: 20))
        _ = try w.write(AudioFixtures.tone(start: 20, seconds: 5))
        let closed = try w.close(at: .init(seconds: 25))
        #expect(closed == [.closed(TrackFile(track: .mic, relativePath: "tracks/mic-001.wav", startOffset: .init(seconds: 20), durationSeconds: 5))])
    }

    @Test func writeWhenClosedThrows() throws {
        let dir = try TemporaryDirectory.make()
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        #expect(throws: WAVSegmentWriterError.notOpen) { try w.write(AudioFixtures.tone(start: 0, seconds: 1)) }
        #expect(try w.close(at: .init(seconds: 1)) == [])
    }
}
