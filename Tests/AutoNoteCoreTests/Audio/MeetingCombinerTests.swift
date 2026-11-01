import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct MeetingCombinerTests {
    private static let base = Samples.start
    private static let newID = MeetingID(rawValue: "20261024-1400-c0de")

    private static func id(_ n: Int) -> MeetingID { MeetingID(rawValue: "20261024-1400-000\(n)") }

    /// A finished live recording that started `start` seconds after `base` and lasted `seconds`.
    private static func recording(_ n: Int, start: Double, seconds: Double, tracks: [TrackFile] = [],
                                  status: MeetingStatus = .transcriptOnly) -> Manifest {
        var m = Samples.manifest
        m.id = id(n)
        // Millisecond precision, as stored, so a saved manifest loads back equal.
        m.startedAt = base.addingTimeInterval(start).truncatedToMilliseconds
        m.endedAt = base.addingTimeInterval(start + seconds).truncatedToMilliseconds
        m.tracks = tracks
        m.status = status
        m.notePath = "/vault/\(n).md"; m.noteTitle = "note \(n)"
        return m
    }

    private static func file(_ track: Track, _ index: Int, at offset: Double, _ seconds: Double) -> TrackFile {
        TrackFile(track: track, relativePath: String(format: "tracks/%@-%03d.wav", track.rawValue, index),
                  startOffset: .init(seconds: offset), durationSeconds: seconds)
    }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    // MARK: - plan (the SPEC §2.5 example at full length: 0–88 s, 90–268 s, 410–2860 s)

    private static var specExample: [Manifest] {
        var first = recording(1, start: 0, seconds: 88, tracks: [file(.mic, 0, at: 0, 88), file(.system, 0, at: 0, 88)])
        first.bookmarks = [Bookmark(at: .init(seconds: 10), note: "a")]
        first.silenceWarning = false
        var second = recording(2, start: 90, seconds: 178, tracks: [file(.mic, 0, at: 0, 178), file(.system, 0, at: 0, 178)])
        second.pauses = [PauseInterval(start: .init(seconds: 50), end: .init(seconds: 60))]
        second.bookmarks = [Bookmark(at: .init(seconds: 5))]
        second.silenceWarning = true
        second.device = DeviceRef(name: "Other", uid: "OTHER", transport: "usb")
        var third = recording(3, start: 410, seconds: 2450, tracks: [
            file(.mic, 0, at: 0, 300), file(.system, 0, at: 0, 300),
            file(.mic, 1, at: 300, 2150), file(.system, 1, at: 300, 2150),
        ])
        third.pauses = [PauseInterval(start: .init(seconds: 2400))]   // paused until the stop
        return [third, first, second]   // any order in
    }

    @Test func planPlacesEachRecordingOnOneTimeline() throws {
        let plan = try MeetingCombiner.plan(Self.specExample, newID: Self.newID)
        let m = plan.manifest
        #expect(m.id == Self.newID)
        #expect(m.startedAt == Self.base)
        #expect(m.endedAt == Self.base.addingTimeInterval(2860))
        #expect(m.source == .live && m.status == .recorded && m.language == .ja)
        #expect(m.silenceWarning)
        #expect(m.device == Samples.manifest.device)
        #expect(m.mergedFrom == [Self.id(1), Self.id(2), Self.id(3)])
        #expect(m.mergedInto == nil && m.title == nil && m.notePath == nil && m.noteTitle == nil)

        let placed = m.tracks.map { ($0.track, $0.relativePath, $0.startOffset.seconds, $0.durationSeconds) }
        let expected: [(Track, String, Double, Double?)] = [
            (.mic, "tracks/mic-000.wav", 0, 88), (.system, "tracks/system-000.wav", 0, 88),
            (.mic, "tracks/mic-001.wav", 90, 178), (.system, "tracks/system-001.wav", 90, 178),
            (.mic, "tracks/mic-002.wav", 410, 300), (.system, "tracks/system-002.wav", 410, 300),
            (.mic, "tracks/mic-003.wav", 710, 2150), (.system, "tracks/system-003.wav", 710, 2150),
        ]
        #expect(placed.count == expected.count)
        for (got, want) in zip(placed, expected) {
            #expect(got.0 == want.0 && got.1 == want.1 && Self.near(got.2, want.2) && got.3 == want.3)
        }

        // The gaps between recordings, then each recording's own pauses (an open one closes at its stop).
        let pauses = m.pauses.map { [$0.start.seconds, $0.end?.seconds ?? -1] }
        #expect(pauses.count == 4)
        let wantPauses: [[Double]] = [[88, 90], [140, 150], [268, 410], [2810, 2860]]
        for (got, want) in zip(pauses, wantPauses) {
            #expect(Self.near(got[0], want[0]) && Self.near(got[1], want[1]))
        }
        #expect(m.bookmarks.map(\.at.seconds) == [10, 95])
        #expect(m.bookmarks.map(\.note) == ["a", nil])
        #expect(Self.near(plan.gapSeconds, 2 + 142))

        // Copies: every source file once, into the new layout.
        #expect(plan.copies.count == 8)
        #expect(plan.copies[2] == .init(source: Self.id(2), from: "tracks/mic-000.wav", to: "tracks/mic-001.wav"))
        #expect(plan.copies[6] == .init(source: Self.id(3), from: "tracks/mic-001.wav", to: "tracks/mic-003.wav"))
    }

    @Test func transcriptTimesRunThroughTheCombinedMeeting() throws {
        // SPEC §2.5: the second recording's first utterance lands near [00:01:30] (its file starts at 90 s).
        let m = try MeetingCombiner.plan(Self.specExample, newID: Self.newID).manifest
        let mic = m.tracks.filter { $0.track == .mic }
        let parts = [TrackTranscription(file: mic[0], utterances: [u(1, .unknown, "はじめ")]),
                     TrackTranscription(file: mic[1], utterances: [u(0.4, .unknown, "つづき")]),
                     TrackTranscription(file: mic[3], utterances: [u(2, .unknown, "後半")])]
        let merged = TranscriptMerger.merge(parts, source: m.source)
        #expect(merged.map(\.start.hhmmss) == ["00:00:01", "00:01:30", "00:11:52"])
        #expect(merged.allSatisfy { $0.speaker == .me })
    }

    @Test func gaplessRecordingsGetNoZeroLengthPause() throws {
        let a = Self.recording(1, start: 0, seconds: 10, tracks: [Self.file(.mic, 0, at: 0, 10)])
        let b = Self.recording(2, start: 10, seconds: 5, tracks: [Self.file(.mic, 0, at: 0, 5)])
        let plan = try MeetingCombiner.plan([a, b], newID: Self.newID)
        #expect(plan.manifest.pauses.isEmpty)
        #expect(plan.gapSeconds == 0)
    }

    // MARK: - plan: precondition failures

    @Test func rejectsFewerThanTwo() {
        #expect(throws: CombineError.tooFew) { try MeetingCombiner.plan([Self.recording(1, start: 0, seconds: 5)], newID: Self.newID) }
        #expect(throws: CombineError.tooFew) { try MeetingCombiner.plan([], newID: Self.newID) }
    }

    @Test func rejectsTheSameMeetingTwice() {
        let a = Self.recording(1, start: 0, seconds: 5)
        #expect(throws: CombineError.duplicate(Self.id(1))) { try MeetingCombiner.plan([a, a], newID: Self.newID) }
    }

    @Test func rejectsARecordingInProgress() {
        var b = Self.recording(2, start: 10, seconds: 5, status: .recording)
        b.endedAt = nil
        #expect(throws: CombineError.recording(Self.id(2))) {
            try MeetingCombiner.plan([Self.recording(1, start: 0, seconds: 5), b], newID: Self.newID)
        }
    }

    @Test(arguments: [MeetingStatus.recorded, .transcribing, .transcribed, .generating])
    func rejectsAMeetingBeingProcessed(_ status: MeetingStatus) {
        let b = Self.recording(2, start: 10, seconds: 5, status: status)
        #expect(throws: CombineError.processing(Self.id(2))) {
            try MeetingCombiner.plan([Self.recording(1, start: 0, seconds: 5), b], newID: Self.newID)
        }
    }

    @Test func rejectsAMeetingWithAnActiveJob() {
        #expect(throws: CombineError.processing(Self.id(1))) {
            try MeetingCombiner.plan([Self.recording(1, start: 0, seconds: 5), Self.recording(2, start: 10, seconds: 5)],
                                     newID: Self.newID, busy: [Self.id(1)])
        }
    }

    @Test func rejectsAnImportedMeeting() {
        var b = Self.recording(2, start: 10, seconds: 5)
        b.source = .imported
        #expect(throws: CombineError.notLive(Self.id(2))) {
            try MeetingCombiner.plan([Self.recording(1, start: 0, seconds: 5), b], newID: Self.newID)
        }
    }

    @Test func rejectsOverlappingRecordings() {
        let a = Self.recording(1, start: 0, seconds: 10)
        let b = Self.recording(2, start: 9.5, seconds: 5)
        #expect(throws: CombineError.overlapping(Self.id(1), Self.id(2))) { try MeetingCombiner.plan([b, a], newID: Self.newID) }
    }

    @Test func rejectsAMeetingAlreadyMerged() {
        var b = Self.recording(2, start: 10, seconds: 5)
        b.mergedInto = MeetingID(rawValue: "20261024-1400-ffff")
        #expect(throws: CombineError.alreadyMerged(Self.id(2), into: MeetingID(rawValue: "20261024-1400-ffff"))) {
            try MeetingCombiner.plan([Self.recording(1, start: 0, seconds: 5), b], newID: Self.newID)
        }
    }

    @Test func rejectsDifferentLanguages() {
        var b = Self.recording(2, start: 10, seconds: 5)
        b.language = .en
        #expect(throws: CombineError.languageMismatch) {
            try MeetingCombiner.plan([Self.recording(1, start: 0, seconds: 5), b], newID: Self.newID)
        }
    }

    @Test func everyErrorHasAMessage() {
        let all: [CombineError] = [.tooFew, .duplicate(Self.id(1)), .recording(Self.id(1)), .processing(Self.id(1)),
                                   .notLive(Self.id(1)), .overlapping(Self.id(1), Self.id(2)),
                                   .alreadyMerged(Self.id(1), into: Self.id(2)), .languageMismatch, .notEnded(Self.id(1))]
        for e in all { #expect(!e.message.isEmpty) }
        #expect(CombineError.notLive(Self.id(2)).message.contains(Self.id(2).rawValue))
    }

    // MARK: - execute (real WAV files, the SPEC example scaled down 20×)

    private struct Store {
        let paths: AppPaths
        let manifests: ManifestStore

        init() throws {
            paths = AppPaths(root: try TemporaryDirectory.make())
            try paths.createBaseDirectories()
            manifests = ManifestStore(paths: paths)
        }

        /// Records `spans` (seconds on this recording's own timeline) on both tracks and saves the manifest.
        func save(_ n: Int, start: Double, spans: [(start: Double, seconds: Double)], value: Int16) async throws -> Manifest {
            let end = spans.map { $0.start + $0.seconds }.max() ?? 0
            var m = MeetingCombinerTests.recording(n, start: start, seconds: end)
            let dir = paths.meetingDirectory(m.id)
            for track in [Track.mic, .system] {
                var w = WAVSegmentWriter(track: track, meetingDirectory: dir)
                for s in spans {
                    var changes = try w.open(at: .init(seconds: s.start))
                    changes += try w.write(AudioFixtures.tone(start: s.start, seconds: s.seconds, value: value, track: track))
                    changes += try w.close(at: .init(seconds: s.start + s.seconds))
                    for case .closed(let f) in changes { m.tracks.append(f) }
                }
            }
            try await manifests.save(m)
            return m
        }

        func names(in dir: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        }
    }

    @Test func executeCopiesTheAudioAndSavesTheManifest() async throws {
        let store = try Store()
        let a = try await store.save(1, start: 0, spans: [(0, 4.4)], value: 1000)
        let b = try await store.save(2, start: 4.5, spans: [(0, 8.9)], value: 2000)
        // Two contiguous files, like a recording longer than one 300 s segment.
        let c = try await store.save(3, start: 20.5, spans: [(0, 15), (15, 107.5)], value: 3000)
        let plan = try MeetingCombiner.plan([c, a, b], newID: Self.newID)
        let saved = try await MeetingCombiner.execute(plan, paths: store.paths, manifests: store.manifests)

        #expect(saved == plan.manifest)
        #expect(try await store.manifests.load(Self.newID) == plan.manifest)
        #expect(store.names(in: store.paths.tracksDirectory(Self.newID)) == [
            "mic-000.wav", "mic-001.wav", "mic-002.wav", "mic-003.wav",
            "system-000.wav", "system-001.wav", "system-002.wav", "system-003.wav",
        ])
        let newDir = store.paths.meetingDirectory(Self.newID)
        let oldB = try WAVFile.readSamples(store.paths.meetingDirectory(b.id).appending(path: "tracks/mic-000.wav"))
        #expect(try WAVFile.readSamples(newDir.appending(path: "tracks/mic-001.wav")) == oldB)
        // The sources are left alone.
        #expect(try await store.manifests.load(a.id) == a)
        #expect(FileManager.default.fileExists(atPath: store.paths.meetingDirectory(c.id).appending(path: "tracks/system-001.wav").path))

        // The gaps between recordings split the merged audio; the two files of the third recording join.
        let merged = try SegmentMerger.merge(saved, track: .mic, meetingDirectory: newDir)
        #expect(merged.count == 3)
        #expect(merged.map(\.relativePath) == ["merged/mic-0.wav", "merged/mic-1.wav", "merged/mic-2.wav"])
        let starts = merged.map(\.startOffset.seconds), durations = merged.map { $0.durationSeconds ?? -1 }
        for (got, want) in zip(starts, [0, 4.5, 20.5]) { #expect(Self.near(got, want)) }
        for (got, want) in zip(durations, [4.4, 8.9, 122.5]) { #expect(abs(got - want) < 0.001) }
    }

    @Test func executeShiftsAndJoinsLiveTranscripts() async throws {
        let store = try Store()
        let a = try await store.save(1, start: 0, spans: [(0, 2)], value: 1000)
        let b = try await store.save(2, start: 3, spans: [(0, 2)], value: 2000)
        let c = try await store.save(3, start: 6, spans: [(0, 2)], value: 3000)
        func writeLive(_ id: MeetingID, _ utterances: [Utterance]) throws {
            let url = store.paths.transcriptFile(id, .live)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AutoNoteJSON.encoder().encode(Transcript(utterances: utterances, engine: "Apple", language: .ja)).write(to: url)
        }
        try writeLive(a.id, [u(0.5, .me, "はじめ", end: 1.5)])
        // b has no live.json
        try writeLive(c.id, [u(0.2, .other, "おわり"), u(1, .me, "以上", end: 1.8)])
        let plan = try MeetingCombiner.plan([a, b, c], newID: Self.newID)
        _ = try await MeetingCombiner.execute(plan, paths: store.paths, manifests: store.manifests)

        let live = try AutoNoteJSON.decoder().decode(Transcript.self,
                                                     from: Data(contentsOf: store.paths.transcriptFile(Self.newID, .live)))
        #expect(live.engine == "Apple" && live.language == .ja)
        #expect(live.utterances.map(\.text) == ["はじめ", "おわり", "以上"])
        let starts = live.utterances.map(\.start.seconds), ends = live.utterances.map { $0.end?.seconds }
        for (got, want) in zip(starts, [0.5, 6.2, 7]) { #expect(Self.near(got, want)) }
        #expect(ends[1] == nil)
        #expect(Self.near(ends[0] ?? 0, 1.5) && Self.near(ends[2] ?? 0, 7.8))
    }

    @Test func executeWritesNoLiveTranscriptWhenNoSourceHasOne() async throws {
        let store = try Store()
        let a = try await store.save(1, start: 0, spans: [(0, 1)], value: 1000)
        let b = try await store.save(2, start: 2, spans: [(0, 1)], value: 2000)
        _ = try await MeetingCombiner.execute(try MeetingCombiner.plan([a, b], newID: Self.newID),
                                              paths: store.paths, manifests: store.manifests)
        #expect(!FileManager.default.fileExists(atPath: store.paths.transcriptFile(Self.newID, .live).path))
    }

    @Test func executeRemovesEverythingWhenAFileIsMissing() async throws {
        let store = try Store()
        let a = try await store.save(1, start: 0, spans: [(0, 1)], value: 1000)
        let b = try await store.save(2, start: 2, spans: [(0, 1)], value: 2000)
        try FileManager.default.removeItem(at: store.paths.meetingDirectory(b.id).appending(path: "tracks/system-000.wav"))
        let plan = try MeetingCombiner.plan([a, b], newID: Self.newID)
        await #expect(throws: CombineError.missingFile(b.id, "tracks/system-000.wav")) {
            try await MeetingCombiner.execute(plan, paths: store.paths, manifests: store.manifests)
        }
        #expect(!FileManager.default.fileExists(atPath: store.paths.meetingDirectory(Self.newID).path))
        #expect(!FileManager.default.fileExists(atPath: store.paths.transcriptsDirectory(Self.newID).path))
        #expect(store.names(in: store.paths.recordingsDirectory) == [a.id.rawValue, b.id.rawValue])
    }

    @Test func executeRefusesAnExistingDirectory() async throws {
        let store = try Store()
        let a = try await store.save(1, start: 0, spans: [(0, 1)], value: 1000)
        let b = try await store.save(2, start: 2, spans: [(0, 1)], value: 2000)
        // A plan whose new id is one of the sources must never touch that directory.
        let plan = try MeetingCombiner.plan([a, b], newID: a.id)
        await #expect(throws: CombineError.destinationExists(a.id)) {
            try await MeetingCombiner.execute(plan, paths: store.paths, manifests: store.manifests)
        }
        #expect(try await store.manifests.load(a.id) == a)
    }
}
