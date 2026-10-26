import Foundation
import Testing
import AutoNoteCore
import AutoNoteTestSupport

@Suite struct LiveTranscriptBufferTests {
    @Test func liveLinesFromFeedSnapshot() {
        // [u(10, 自分), 印(20, "── ブックマーク ──"), u(30, 相手, isFinal false)] → [.utterance, .marker, .utterance]
        let me = u(10, .me, "こんにちは")
        let marker = Utterance(start: TimelineTime(seconds: 20), speaker: .unknown, text: "── ブックマーク ──", isFinal: true)
        let other = Utterance(start: TimelineTime(seconds: 30), speaker: .other, text: "途中", isFinal: false)
        var b = LiveTranscriptBuffer()
        #expect(b.lines.isEmpty)
        b.update([me, marker, other])
        #expect(b.lines == [.utterance(me), .marker(marker), .utterance(other)])
        // update のたびに全体を置き換える
        let replaced = Utterance(start: TimelineTime(seconds: 30), speaker: .other, text: "途中でした", isFinal: true)
        b.update([me, replaced])
        #expect(b.lines == [.utterance(me), .utterance(replaced)])
        // reset で空
        b.reset()
        #expect(b.lines.isEmpty && b == LiveTranscriptBuffer())
    }
}
