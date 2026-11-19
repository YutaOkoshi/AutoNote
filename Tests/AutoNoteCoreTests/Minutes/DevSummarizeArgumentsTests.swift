import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct DevSummarizeArgumentsTests {
    @Test func parsesAllOptions() throws {
        let a = try DevSummarizeArguments.parse(
            ["--fake", "t.json", "--out", "d", "--minutes", "m.json", "--fail-summary"])
        #expect(a.transcript.lastPathComponent == "t.json")
        #expect(a.out.lastPathComponent == "d")
        #expect(a.minutes?.lastPathComponent == "m.json")
        #expect(a.failSummary)
        #expect(!a.useClaude)
    }

    @Test func requiresFakeAndOut() {
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--minutes", "m.json"])
        }
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--out", "d", "--minutes", "m.json"])
        }
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--bogus"])
        }
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--out"])
        }
    }

    @Test func parsesMinutesOut() throws {
        let a = try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--claude", "--minutes-out", "o.json"])
        #expect(a.minutesOut?.lastPathComponent == "o.json")
        let none = try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--claude"])
        #expect(none.minutesOut == nil)
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--claude", "--minutes-out"])
        }
    }

    @Test func exportMinutesWritesTheMinutesJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "DevSummarizeExport-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let minutes = try #require(try FixtureLibrary.meetings().compactMap(\.minutes).first)
        let source = dir.appending(path: "minutes.json")
        try AutoNoteJSON.encoder().encode(minutes).write(to: source)
        let dest = dir.appending(path: "nested/out.json")

        try DevSummarizeArguments.exportMinutes(from: source, to: dest)

        let decoded = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(contentsOf: dest))
        #expect(decoded == minutes)
    }

    @Test func exportMinutesRejectsSomethingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "DevSummarizeExport-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "minutes.json")
        try Data(#"{"not":"minutes"}"#.utf8).write(to: source)
        let dest = dir.appending(path: "out.json")
        #expect(throws: (any Error).self) { try DevSummarizeArguments.exportMinutes(from: source, to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func minutesRequiredUnlessFailOrClaude() throws {
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d"])
        }
        let claude = try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--claude"])
        #expect(claude.useClaude && claude.minutes == nil)
        let failing = try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--fail-summary"])
        #expect(failing.failSummary && failing.minutes == nil)
    }

    // MARK: fake tracks (`--fake` keeps "me" and "other" apart)

    private func utterance(_ start: Double, _ speaker: Speaker, _ text: String) -> Utterance {
        Utterance(start: TimelineTime(seconds: start), end: TimelineTime(seconds: start + 1), speaker: speaker, text: text,
                  isFinal: true)
    }

    @Test func otherSpeakerGoesToTheSystemTrack() {
        let input = [utterance(0, .me, "a"), utterance(1, .other, "b"), utterance(2, .unknown, "c"), utterance(3, .other, "d")]
        let plan = DevSummarizeArguments.fakeTracks(input)
        #expect(plan.map(\.track) == [.mic, .system])
        #expect(plan[0].utterances.map(\.text) == ["a", "c"])
        #expect(plan[1].utterances.map(\.text) == ["b", "d"])
        #expect(plan.map(\.relativePath) == ["tracks/mic-000.wav", "tracks/system-000.wav"])
        #expect(plan.map(\.mergedFileName) == ["mic-0.wav", "system-0.wav"])
    }

    @Test func withoutOtherSpeakerThereIsOnlyTheMicTrack() {
        let plan = DevSummarizeArguments.fakeTracks([utterance(0, .unknown, "a"), utterance(1, .me, "b")])
        #expect(plan.map(\.track) == [.mic])
        #expect(plan[0].utterances.count == 2)
    }

    @Test func mergingThePlannedTracksRestoresTheSpeakers() {
        let input = [utterance(0, .me, "a"), utterance(1, .other, "b"), utterance(2, .me, "c")]
        let parts = DevSummarizeArguments.fakeTracks(input).map { t in
            TrackTranscription(file: TrackFile(track: t.track, relativePath: t.relativePath,
                                               startOffset: TimelineTime(seconds: 0), durationSeconds: 1),
                               utterances: t.utterances)
        }
        let merged = TranscriptMerger.merge(parts, source: .live)
        #expect(merged.map(\.speaker) == [.me, .other, .me])
        #expect(merged.map(\.text) == ["a", "b", "c"])
    }
}
