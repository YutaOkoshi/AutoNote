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

@Test func rendersParagraphsAndPause() {
    #expect(TranscriptMarkdown.render([u(5, .me, "a"), u(200, .other, "b\nc")], pauses: [PauseInterval(start: .init(seconds: 150), end: .init(seconds: 170))]) ==
        "**[00:00:05] 自分**: a ^t00-00-05\n\n── 一時停止 00:02:30〜00:02:50 ──\n\n**[00:03:20] 相手**: b c ^t00-03-20\n")
}
