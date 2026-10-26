import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

private func part(_ track: Track, _ path: String, _ offset: Double, _ us: [Utterance]) -> TrackTranscription {
    TrackTranscription(file: TrackFile(track: track, relativePath: path, startOffset: .init(seconds: offset), durationSeconds: nil), utterances: us)
}

@Test func mergeShiftsByStartOffsetAndSorts() {
    let merged = TranscriptMerger.merge([part(.mic, "tracks/mic-001.wav", 170, [u(2, .unknown, "c", end: 4)]),
                                         part(.mic, "tracks/mic-000.wav", 0, [u(5, .unknown, "a")]),
                                         part(.system, "tracks/system-000.wav", 0, [u(5, .unknown, "b")])], source: .live)
    #expect(merged.map(\.text) == ["a", "b", "c"]); #expect(merged.map(\.speaker) == [.me, .other, .me])
    #expect(merged[2].start.seconds == 172); #expect(merged[2].end?.seconds == 174)
    #expect(TranscriptMerger.merge([part(.mic, "tracks/import-000.wav", 0, [u(1, .me, "x")])], source: .imported)[0].speaker == .unknown)
}

@Test func mergeKeepsOriginalOrderWithinTrackOnTies() {
    let merged = TranscriptMerger.merge([part(.mic, "tracks/mic-000.wav", 0, [u(1, .unknown, "first"), u(1, .unknown, "second")])], source: .live)
    #expect(merged.map(\.text) == ["first", "second"])
}
