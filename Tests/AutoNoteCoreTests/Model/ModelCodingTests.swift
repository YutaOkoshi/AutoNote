import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test func manifestRoundTripsWithSnakeCaseKeys() throws {
    var m = Samples.manifest
    m.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .zero, durationSeconds: 150)]
    m.pauses = [PauseInterval(start: .init(seconds: 150), end: nil)]; m.bookmarks = [Bookmark(at: .init(seconds: 41.5), note: "価格の話")]
    let s = String(decoding: try AutoNoteJSON.encoder().encode(m), as: UTF8.self)
    for key in ["started_at", "relative_path", "start_offset", "silence_warning", "autonote_version"] { #expect(s.contains("\"\(key)\"")) }
    #expect(s.contains(#""status" : "minutes_generated""#))
    #expect(try AutoNoteJSON.decoder().decode(Manifest.self, from: Data(s.utf8)) == m)
    #expect(m.duration == 3720.0)
}

@Test func minutesOutputMatchesSchemaShape() throws {
    let json = #"{"title":"定例","summary":["a","b","c"],"decisions":[{"text":"来週出す","t":"00:12:34"}],"agenda":[{"title":"判定","body":"本文","t":"00:03:10"}],"next_actions":[{"text":"更新","owner":null,"due":"10/31","t":"00:40:02"}],"suggested_terms":["ルミナ茶"]}"#
    let m = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(json.utf8))
    #expect(m.nextActions[0].owner == nil); #expect(m.nextActions[0].due == "10/31"); #expect(m.decisions[0].time == TimelineTime(seconds: 754))
    let back = String(decoding: try AutoNoteJSON.encoder().encode(m), as: UTF8.self)
    #expect(back.contains(#""owner" : null"#)); #expect(back.contains(#""next_actions""#))
}

@Test func samplesAreAsSpecified() {
    #expect(Samples.manifest.id.rawValue == "20261024-1400-a1b2")
    #expect(Samples.minutes.summary.first == "リリースは来週に決定")
    #expect(Samples.minutes.nextActions[0].owner == "自分")
    #expect(u(5, .me, "x").isFinal)
    #expect(MeetingStatus.tooShort.rawValue == "too_short")
}
