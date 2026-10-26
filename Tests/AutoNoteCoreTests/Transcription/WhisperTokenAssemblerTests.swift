import Testing
@testable import AutoNoteCore

@Suite struct WhisperTokenAssemblerTests {
    @Test func validTokensPassThrough() {
        var a = WhisperTokenAssembler()
        #expect(a.append(bytes: Array("会議".utf8), t0: 0, t1: 0.5) == [TimedToken(start: 0, end: 0.5, text: "会議")])
        #expect(a.append(bytes: Array(" ok".utf8), t0: 0.5, t1: 0.7) == [TimedToken(start: 0.5, end: 0.7, text: " ok")])
        #expect(a.flush().isEmpty)
    }

    @Test func splitCharactersAreMerged() {
        let bytes = Array("日本".utf8)   // 6 bytes: 日 = 0..<3, 本 = 3..<6
        var a = WhisperTokenAssembler()
        #expect(a.append(bytes: Array(bytes[0..<2]), t0: 1.0, t1: 1.1).isEmpty)
        #expect(a.append(bytes: Array(bytes[2..<4]), t0: 1.1, t1: 1.2).isEmpty)
        #expect(a.append(bytes: Array(bytes[4..<6]), t0: 1.2, t1: 1.4) == [TimedToken(start: 1.0, end: 1.4, text: "日本")])
        #expect(a.flush().isEmpty)
    }

    @Test func splitThenValidKeepsOrder() {
        let bytes = Array("日".utf8)
        var a = WhisperTokenAssembler()
        #expect(a.append(bytes: Array(bytes[0..<1]), t0: 0, t1: 0.1).isEmpty)
        #expect(a.append(bytes: Array(bytes[1..<3]), t0: 0.1, t1: 0.2) == [TimedToken(start: 0, end: 0.2, text: "日")])
        #expect(a.append(bytes: Array("本".utf8), t0: 0.2, t1: 0.3) == [TimedToken(start: 0.2, end: 0.3, text: "本")])
    }

    @Test func flushDecodesLeftoverLossily() {
        var a = WhisperTokenAssembler()
        #expect(a.append(bytes: Array(Array("日".utf8)[0..<2]), t0: 2, t1: 2.1).isEmpty)
        let rest = a.flush()
        #expect(rest.count == 1)
        #expect(rest.first?.start == 2)
        #expect(rest.first?.end == 2.1)
        #expect(a.flush().isEmpty)
    }
}
