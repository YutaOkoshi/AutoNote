import Testing
import Foundation
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test func anchorsAreUniquePerSecond() { #expect(TranscriptMarkdown.anchors(for: [u(40.0, .other, "a"), u(40.6, .me, "b"), u(60, .me, "c")]) == ["t00-00-40", "t00-00-40-2", "t00-01-00"]) }

@Test func linkTargetFallsBackToPreviousUtterance() {
    let us = [u(5, .me, "a"), u(12, .other, "b"), u(30, .me, "c")]; let a = TranscriptMarkdown.anchors(for: us)
    #expect(TranscriptMarkdown.linkTarget(for: .init(seconds: 20), utterances: us, anchors: a) == "t00-00-12")
    #expect(TranscriptMarkdown.linkTarget(for: .init(seconds: 2), utterances: us, anchors: a) == "t00-00-05")
    #expect(TranscriptMarkdown.linkTarget(for: .zero, utterances: [], anchors: []) == nil)
    #expect(MeetingDocument.link(.init(seconds: 21), anchor: "t00-00-12") == "[[#^t00-00-12|00:21]]")
    #expect(MeetingDocument.link(.init(seconds: 21), anchor: nil) == "00:21")
}

@Test func linkTargetMatchesTheDisplayedSecond() {
    let us = [u(8, .me, "前の発話", end: 11), u(12.4, .other, "対象の発話", end: 15)]; let a = TranscriptMarkdown.anchors(for: us)
    #expect(TranscriptMarkdown.linkTarget(for: TimelineTime(hhmmss: "00:00:12")!, utterances: us, anchors: a) == "t00-00-12")
}

@Test func linkTargetPrefersTheUtteranceContainingTheTime() {
    let us = [u(40, .other, "一本百八十円でいきましょう。", end: 46), u(40.6, .me, "はい。", end: 41), u(50, .me, "次", end: 52)]
    let a = TranscriptMarkdown.anchors(for: us)
    #expect(TranscriptMarkdown.linkTarget(for: TimelineTime(hhmmss: "00:00:42")!, utterances: us, anchors: a) == "t00-00-40")
    #expect(TranscriptMarkdown.linkTarget(for: .init(seconds: 41.5), utterances: us, anchors: a) == "t00-00-40")
    #expect(TranscriptMarkdown.linkTarget(for: .init(seconds: 40.8), utterances: us, anchors: a) == "t00-00-40-2")
    #expect(TranscriptMarkdown.linkTarget(for: .init(seconds: 48), utterances: us, anchors: a) == "t00-00-40-2")
    // 00:00:40 is inside 40–46 s; 「はい。」 shares the displayed second but has not started yet.
    #expect(TranscriptMarkdown.linkTarget(for: TimelineTime(hhmmss: "00:00:40")!, utterances: us, anchors: a) == "t00-00-40")
}

@Test func rendersParagraphsAndPause() {
    #expect(TranscriptMarkdown.render([u(5, .me, "a"), u(200, .other, "b\nc")], pauses: [PauseInterval(start: .init(seconds: 150), end: .init(seconds: 170))]) ==
        "**[00:00:05] 自分**: a ^t00-00-05\n\n── 一時停止 00:02:30〜00:02:50 ──\n\n**[00:03:20] 相手**: b c ^t00-03-20\n")
}
