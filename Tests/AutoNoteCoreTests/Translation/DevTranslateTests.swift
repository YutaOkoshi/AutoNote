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

    @Test func parsesTheSummaryFiles() throws {
        let a = try DevTranslateArguments.parse(["t.json", "--minutes", "m.json", "--live-summary", "l.json"])
        #expect(a.minutes?.lastPathComponent == "m.json" && a.liveSummary?.lastPathComponent == "l.json")
        #expect(try DevTranslateArguments.parse(["t.json"]).minutes == nil)
        for bad in [["t.json", "--minutes"], ["t.json", "--live-summary"]] {
            #expect(throws: DevTranslateArguments.Invalid.self) { try DevTranslateArguments.parse(bad) }
        }
    }

    @Test func theSummariesAreTranslatedIntoTheOppositeOfTheirLanguage() async throws {
        let t = Transcript(utterances: [utterance(0, "Hello there.")], engine: "fake", language: .auto)
        let minutes = MinutesOutput(title: "移行の定例", summary: ["六割を移した。"],
                                    decisions: [Decision(text: "月末までに終える", t: "00:01:00")], agenda: [],
                                    nextActions: [NextAction(text: "手順書を送る", owner: "佐藤", t: "00:02:00")],
                                    suggestedTerms: [])
        let live = LiveSummaryState(now: "Migration status", decisions: ["Finish by month end"], todos: [],
                                    consumedThrough: 10, updatedAt: nil)
        let line = try await DevTranslateLine.make(transcript: t, target: .auto, model: "fake", completer: FakeTextCompleter(),
                                                   minutes: minutes, liveSummary: live)
        let json = String(decoding: try line.encoded(), as: UTF8.self)
        #expect(json.contains(#""minutes":{"entries":[{"source":"移行の定例","source_lang":"ja","target_lang":"en","text":"EN: 移行の定例"},{"source":"六割を移した。","source_lang":"ja","target_lang":"en","text":"EN: 六割を移した。"},{"source":"月末までに終える","source_lang":"ja","target_lang":"en","text":"EN: 月末までに終える"},{"source":"手順書を送る","source_lang":"ja","target_lang":"en","text":"EN: 手順書を送る"}],"summary_lang":"ja","target_lang":"en"}"#))
        #expect(json.contains(#""live_summary":{"entries":[{"source":"Migration status","source_lang":"en","target_lang":"ja","text":"JA: Migration status"},{"source":"Finish by month end","source_lang":"en","target_lang":"ja","text":"JA: Finish by month end"}],"summary_lang":"en","target_lang":"ja"}"#))
        // A fixed target equal to the summary's language: nothing translated.
        let same = try await DevTranslateLine.make(transcript: t, target: .ja, model: "fake", completer: FakeTextCompleter(),
                                                   minutes: minutes)
        #expect(String(decoding: try same.encoded(), as: UTF8.self).contains(#""minutes":{"entries":[],"summary_lang":"ja"}"#))
        // Without summary files the line is exactly as before.
        let plain = try await DevTranslateLine.make(transcript: t, target: .auto, model: "fake", completer: FakeTextCompleter())
        #expect(!String(decoding: try plain.encoded(), as: UTF8.self).contains("minutes"))
    }
}
