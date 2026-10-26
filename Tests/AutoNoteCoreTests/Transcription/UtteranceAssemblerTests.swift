import Testing
@testable import AutoNoteCore

@Suite struct UtteranceAssemblerTests {
    @Test func partialsShareStartUntilFinal() {
        var m = TimelineMapper(); m.append(chunk(silence(5), at: 30))
        var a = UtteranceAssembler()
        let u = [RecognizedSegment(audioStart: 0, audioEnd: 1, text: "こん", isFinal: false),
                 .init(audioStart: 0.3, audioEnd: 1.5, text: "こんにちは", isFinal: false),
                 .init(audioStart: 0, audioEnd: 2, text: "こんにちは", isFinal: true),
                 .init(audioStart: 2.5, audioEnd: 3, text: "次", isFinal: false)].map { a.consume($0, mapper: m) }
        #expect(u.map(\.start.seconds) == [30, 30, 30, 32.5]); #expect(u.map(\.isFinal) == [false, false, true, false])
        #expect(u[2].end?.seconds == 32); #expect(u[0].end == nil)
    }

    @Test func keepsTextAndLeavesSpeakerUnknown() {
        var m = TimelineMapper(); m.append(chunk(silence(2), at: 0))
        var a = UtteranceAssembler()
        let u = a.consume(RecognizedSegment(audioStart: 0.5, audioEnd: 1, text: "会議", isFinal: true), mapper: m)
        #expect(u == Utterance(start: TimelineTime(seconds: 0.5), end: TimelineTime(seconds: 1), speaker: .unknown, text: "会議", isFinal: true))
    }

    @Test func consecutiveFinalsEachUseTheirOwnStart() {
        var m = TimelineMapper(); m.append(chunk(silence(5), at: 10))
        var a = UtteranceAssembler()
        let u = [RecognizedSegment(audioStart: 0, audioEnd: 1, text: "一", isFinal: true),
                 .init(audioStart: 1.2, audioEnd: 2, text: "二", isFinal: true)].map { a.consume($0, mapper: m) }
        #expect(u.map(\.start.seconds) == [10, 11.2]); #expect(u.map { $0.end?.seconds } == [11, 12])
    }
}
