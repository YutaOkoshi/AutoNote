import Testing
import Foundation
import AVFoundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct CrashRecoveryTests {
    private struct Env {
        let paths: AppPaths
        let store: ManifestStore
        let recovery: CrashRecovery
    }

    private func makeEnv() throws -> Env {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = ManifestStore(paths: paths)
        return Env(paths: paths, store: store, recovery: CrashRecovery(paths: paths, manifests: store))
    }

    private func manifest(_ suffix: String, status: MeetingStatus = .recording,
                          tracks: [TrackFile] = [], pauses: [PauseInterval] = []) -> Manifest {
        var m = Samples.manifest
        m.id = MeetingID.make(start: Samples.start, timeZone: Samples.tokyo, suffix: suffix)
        m.status = status
        m.endedAt = nil
        m.tracks = tracks
        m.pauses = pauses
        return m
    }

    private func zero(_ url: URL, at offsets: [UInt64]) throws {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        for o in offsets { try h.seek(toOffset: o); try h.write(contentsOf: Data(count: 4)) }
    }

    @Test func findsOnlyRecordingStatus() async throws {
        let env = try makeEnv()
        let a = manifest("aaaa"), b = manifest("bbbb", status: .recorded), c = manifest("cccc", status: .tooShort)
        for m in [a, b, c] { try await env.store.save(m) }
        let found = try await env.recovery.findInterrupted()
        #expect(found.map(\.id) == [a.id])
        #expect(try await env.recovery.findInterrupted(excluding: a.id).isEmpty)
    }

    @Test func recoverRepairsUnfinalizedHeader() async throws {
        let env = try makeEnv()
        var m = manifest("dddd")
        let dir = env.paths.meetingDirectory(m.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir, segmentSeconds: 300)
        var changes = try w.open(at: .init(seconds: 0))
        for i in 0..<300 { changes += try w.write(AudioFixtures.tone(start: Double(i), seconds: 1)) }
        for i in 300..<390 { changes += try w.write(AudioFixtures.tone(start: Double(i), seconds: 1)) }
        changes += try w.close(at: .init(seconds: 390))
        // Simulate a crash: sizes were never finalized in the second file.
        let second = dir.appending(path: "tracks/mic-001.wav")
        try zero(second, at: [4, 40])
        m.tracks = changes.compactMap { change in
            switch change {
            case .opened(let f): return f
            case .closed(var f): if f.relativePath.hasSuffix("001.wav") { f.durationSeconds = nil }; return f
            }
        }
        // Keep one entry per file (closed replaces opened).
        var byPath: [String: TrackFile] = [:]
        for t in m.tracks { byPath[t.relativePath] = t }
        m.tracks = byPath.values.sorted { $0.relativePath < $1.relativePath }
        try await env.store.save(m)

        let r = try await env.recovery.recover(m.id)
        #expect(r.tracks.count == 2)
        #expect(r.tracks[1].durationSeconds == 90)
        #expect(try WAVFile.info(second).durationSeconds == 90)
        let f = try AVAudioFile(forReading: second)
        #expect(f.length == 90 * 16_000)
        #expect(r.status == .recorded)
        #expect(r.endedAt == m.startedAt.addingTimeInterval(390))
        #expect(try await env.store.load(m.id) == r)
    }

    @Test func dropsMissingAndEmptySegments() async throws {
        let env = try makeEnv()
        var m = manifest("eeee")
        let dir = env.paths.meetingDirectory(m.id)
        try FileManager.default.createDirectory(at: dir.appending(path: "tracks"), withIntermediateDirectories: true)
        let good = dir.appending(path: "tracks/mic-000.wav")
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0)); _ = try w.write(AudioFixtures.tone(start: 0, seconds: 70))
        _ = try w.close(at: .init(seconds: 70))
        let header = try Data(contentsOf: good).prefix(44)
        try Data(header).write(to: dir.appending(path: "tracks/mic-002.wav"))
        m.tracks = [
            TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0)),
            TrackFile(track: .mic, relativePath: "tracks/mic-001.wav", startOffset: .init(seconds: 70)),
            TrackFile(track: .mic, relativePath: "tracks/mic-002.wav", startOffset: .init(seconds: 80)),
        ]
        try await env.store.save(m)
        let r = try await env.recovery.recover(m.id)
        #expect(r.tracks.map(\.relativePath) == ["tracks/mic-000.wav"])
        #expect(r.tracks[0].durationSeconds == 70)
        #expect(r.status == .recorded)
    }

    @Test func dropsFileWithCorruptHeader() async throws {
        let env = try makeEnv()
        var m = manifest("iiii")
        let dir = env.paths.meetingDirectory(m.id)
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0)); _ = try w.write(AudioFixtures.tone(start: 0, seconds: 70))
        _ = try w.close(at: .init(seconds: 70))
        try Data(repeating: 0xAB, count: 100).write(to: dir.appending(path: "tracks/mic-001.wav"))
        m.tracks = [
            TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0)),
            TrackFile(track: .mic, relativePath: "tracks/mic-001.wav", startOffset: .init(seconds: 70)),
        ]
        try await env.store.save(m)
        let r = try await env.recovery.recover(m.id)
        #expect(r.tracks.map(\.relativePath) == ["tracks/mic-000.wav"])
        #expect(r.tracks[0].durationSeconds == 70)
        #expect(r.status == .recorded)
    }

    @Test func closesOpenPause() async throws {
        let env = try makeEnv()
        var m = manifest("ffff", pauses: [PauseInterval(start: .init(seconds: 30))])
        let dir = env.paths.meetingDirectory(m.id)
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0)); _ = try w.write(AudioFixtures.tone(start: 0, seconds: 80))
        _ = try w.close(at: .init(seconds: 80))
        m.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0))]
        try await env.store.save(m)
        let r = try await env.recovery.recover(m.id)
        #expect(r.pauses == [PauseInterval(start: .init(seconds: 30), end: .init(seconds: 80))])
    }

    @Test func shortInterruptedRecordingBecomesTooShort() async throws {
        let env = try makeEnv()
        var m = manifest("gggg")
        let dir = env.paths.meetingDirectory(m.id)
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0)); _ = try w.write(AudioFixtures.tone(start: 0, seconds: 20))
        _ = try w.close(at: .init(seconds: 20))
        m.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0))]
        try await env.store.save(m)
        let r = try await env.recovery.recover(m.id)
        #expect(r.status == .tooShort)
        #expect(r.endedAt == m.startedAt.addingTimeInterval(20))
    }

    @Test func discardDeletesMeetingDirectory() async throws {
        let env = try makeEnv()
        let m = manifest("hhhh")
        try await env.store.save(m)
        try await env.recovery.discard(m.id)
        #expect(!FileManager.default.fileExists(atPath: env.paths.meetingDirectory(m.id).path))
        #expect(await env.store.all().isEmpty)
    }
}
