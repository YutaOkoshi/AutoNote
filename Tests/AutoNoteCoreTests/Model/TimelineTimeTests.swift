import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test func formatsAndParsesTimelineTime() {
    let t = TimelineTime(seconds: 754.9)
    #expect(t.hhmmss == "00:12:34"); #expect(t.anchor == "t00-12-34"); #expect(t.mmss == "12:34")
    #expect(TimelineTime(seconds: 3910).mmss == "1:05:10"); #expect(TimelineTime(seconds: -2).hhmmss == "00:00:00")
    #expect((TimelineTime(seconds: 2) + TimelineTime(seconds: 170)).seconds == 172)
    #expect(TimelineTime(hhmmss: "00:40:02")?.seconds == 2402)
    #expect(TimelineTime(hhmmss: "00:61:00") == nil); #expect(TimelineTime(hhmmss: "12:34") == nil)
}

@Test func idAndTimeEncodeAsSingleValues() throws {
    let id = MeetingID.make(start: Samples.start, timeZone: Samples.tokyo, suffix: "a1b2")
    #expect(id.rawValue == "20261024-1400-a1b2"); #expect(MeetingID.randomSuffix().wholeMatch(of: /[0-9a-f]{4}/) != nil)
    #expect(String(decoding: try AutoNoteJSON.encoder().encode(id), as: UTF8.self) == #""20261024-1400-a1b2""#)
    #expect(String(decoding: try AutoNoteJSON.encoder().encode(TimelineTime(seconds: 1.5)), as: UTF8.self) == "1.5")
    #expect([Speaker.me, .other, .unknown].map(\.displayName) == ["自分", "相手", "不明"])
    #expect(Transcript.fallbackEngineLabel(live: "Dictation") == "Dictation（確定版の失敗によりリアルタイム版で代用）")
}

@Test func hhmmssRejectsHugeHours() {
    #expect(TimelineTime(hhmmss: "12345678901234567890:00:00") == nil)   // 20 digits
    #expect(TimelineTime(hhmmss: "9000000000000000000:00:00") == nil)    // fits Int, but h * 3600 would overflow
    #expect(TimelineTime(hhmmss: "100000:00:00") == nil)
    #expect(TimelineTime(hhmmss: "99999:59:59")?.seconds == 359_999_999)
}
