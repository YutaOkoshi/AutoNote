import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct DevTranslateTests {
    @Test func parsesTheArguments() throws {
        let a = try DevTranslateArguments.parse(["t.json"])
        #expect(a.transcript.lastPathComponent == "t.json" && a.target == .auto && a.model == nil)
        let b = try DevTranslateArguments.parse(["--target", "en", "t.json", "--model", "/m/x.gguf"])
        #expect(b.target == .en && b.model?.path == "/m/x.gguf")
        for bad in [[], ["--target", "fr", "t.json"], ["t.json", "u.json"], ["t.json", "--model"], ["--bogus", "t.json"]] {
            #expect(throws: DevTranslateArguments.Invalid.self) { try DevTranslateArguments.parse(bad) }
        }
    }

    @Test func lineIsDeterministicWithTheFake() async throws {
        let t = Transcript(utterances: [utterance(0, "Hello there."), utterance(2, "123"), utterance(4, "了解です。", .me)],
                           engine: "fake", language: .auto)
        let line = try await DevTranslateLine.make(transcript: t, target: .auto, model: "fake", completer: FakeTextCompleter())
        let json = String(decoding: try line.encoded(), as: UTF8.self)
        #expect(!json.contains("\n"))
        #expect(json == #"{"entries":[{"index":0,"source_lang":"en","target_lang":"ja","text":"JA: Hello there."},{"index":2,"source_lang":"ja","target_lang":"en","text":"EN: 了解です。"}],"model":"fake","skipped":[1],"target":"auto","utterances":3}"#)
    }
}
