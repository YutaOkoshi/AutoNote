import Testing
import Foundation
@testable import AutoNoteCore

@Suite struct LiveSummaryInputTests {
    private func u(_ start: Double, _ end: Double?, _ text: String, final: Bool = true) -> Utterance {
        Utterance(start: TimelineTime(seconds: start), end: end.map { TimelineTime(seconds: $0) },
                  speaker: .me, text: text, isFinal: final)
    }

    private func state(consumedThrough: Double) -> LiveSummaryState {
        var s = LiveSummaryState.empty
        s.consumedThrough = consumedThrough
        return s
    }

    private func ends(_ r: LiveSummaryRequest) -> [Double] { r.utterances.map { ($0.end ?? $0.start).seconds } }

    @Test func firstCallSendsEveryConfirmedUtterance() throws {
        let all = [u(0, 9, "a"), u(10, 45, "b"), u(50, 85, "c")]
        let r = try #require(LiveSummaryInputBuilder.request(previous: .empty, confirmed: all))
        #expect(r.utterances == all && r.consumedThrough == 85 && r.previous == .empty)
    }

    @Test func noNewUtteranceIsNil() {
        let all = [u(0, 9, "a"), u(10, 45, "b"), u(50, 85, "c")]
        #expect(LiveSummaryInputBuilder.request(previous: state(consumedThrough: 85), confirmed: all) == nil)
    }

    @Test func includesTheLast120Seconds() throws {
        let all = [u(90, 100, "a"), u(190, 200, "b"), u(240, 250, "c"), u(280, 290, "d"), u(300, 310, "e")]
        let r = try #require(LiveSummaryInputBuilder.request(previous: state(consumedThrough: 300), confirmed: all))
        #expect(ends(r) == [200, 250, 290, 310])
        #expect(r.consumedThrough == 310)
    }

    @Test func partialsAndMarkersAreIgnored() throws {
        let marker = Utterance(start: TimelineTime(seconds: 95), speaker: .unknown, text: LiveFeed.pauseMarkerText, isFinal: true)
        let old = [u(0, 9, "a")]
        let onlyNoise = old + [u(20, 30, "途中", final: false), marker, u(40, 50, "  ")]
        #expect(LiveSummaryInputBuilder.request(previous: state(consumedThrough: 9), confirmed: onlyNoise) == nil)
        let mixed = onlyNoise + [u(60, 70, "新しい")]
        let r = try #require(LiveSummaryInputBuilder.request(previous: state(consumedThrough: 9), confirmed: mixed))
        #expect(r.utterances.map(\.text) == ["a", "新しい"])
        #expect(r.consumedThrough == 70)
        #expect(LiveSummaryInputBuilder.finalUtterances(mixed).map(\.text) == ["a", "新しい"])
    }

    @Test func missingEndUsesStart() throws {
        let r = try #require(LiveSummaryInputBuilder.request(previous: .empty, confirmed: [u(50, nil, "a")]))
        #expect(r.consumedThrough == 50)
    }

    @Test func trimsOldestBeyond8000WithMarker() throws {
        let all = (0..<120).map { i in u(Double(i), Double(i) + 1, "\(i)話" + String(repeating: "あ", count: 80)) }
        let block = LiveSummaryInputBuilder.transcriptBlock(all)
        let lines = block.components(separatedBy: "\n")
        #expect(block.count <= 8_000)
        #expect(lines.first == "[前略]")
        #expect(lines.last == PromptBuilder.line(all[119]))
        #expect(lines.count > 2)
    }

    @Test func shortBlockHasNoMarker() {
        let all = [u(5, 6, "こんにちは"), u(12, 13, "よろしく")]
        #expect(LiveSummaryInputBuilder.transcriptBlock(all) == "[00:00:05] 自分: こんにちは\n[00:00:12] 自分: よろしく")
    }

    @Test func singleHugeUtteranceIsCut() {
        let text = (0..<9_000).map { i in String(UnicodeScalar(UInt8(65 + i % 26))) }.joined()
        let block = LiveSummaryInputBuilder.transcriptBlock([u(0, 10, text)])
        #expect(block.count <= 8_000)
        #expect(block.hasPrefix("[前略]"))
        #expect(block.hasSuffix(String(text.suffix(100))))
    }

    @Test func promptOrderIsInstructionsNoticeStateLines() throws {
        let previous = LiveSummaryState(now: "予算", decisions: ["A"], todos: [.init(text: "送る", owner: nil)],
                                        consumedThrough: 10, updatedAt: nil)
        let r = try #require(LiveSummaryInputBuilder.request(previous: previous, confirmed: [u(5, 10, "前"), u(20, 30, "後")]))
        let prompt = LiveSummaryInputBuilder.prompt(r)
        func pos(_ s: String) throws -> String.Index { try #require(prompt.range(of: s)).lowerBound }
        let order = try [DefaultPrompt.liveInstructions, DefaultPrompt.liveDataNotice, "## 前回の状態", "## 発話"].map(pos)
        #expect(order == order.sorted())
        let json = try #require(String(data: try AutoNoteJSON.compactEncoder().encode(previous.output), encoding: .utf8))
        #expect(prompt.contains("## 前回の状態\n" + json + "\n\n## 発話\n"))
        #expect(prompt.hasSuffix("## 発話\n" + LiveSummaryInputBuilder.transcriptBlock(r.utterances)))
    }

    @Test func liveInstructionsStateTheRules() {
        for phrase in ["発話と同じ言語で書く", "推測で決定事項を作らない", "決まっていないことは宿題にも入れない", "名詞中心の 1 文"] {
            #expect(DefaultPrompt.liveInstructions.contains(phrase))
        }
    }

    @Test func schemaIsValidJSONWithCaps() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(LiveSummarySchema.json.utf8)) as? [String: Any])
        #expect(object["required"] as? [String] == ["now", "decisions", "todos"])
        let props = try #require(object["properties"] as? [String: Any])
        #expect((props["now"] as? [String: Any])?["maxLength"] as? Int == 60)
        #expect((props["decisions"] as? [String: Any])?["maxItems"] as? Int == 50)
        #expect((props["todos"] as? [String: Any])?["maxItems"] as? Int == 50)
    }

    @Test func constantsAreFixed() {
        #expect(LiveSummaryInputBuilder.contextSeconds == 120)
        #expect(LiveSummaryInputBuilder.characterLimit == 8_000)
        #expect(LiveSummaryInputBuilder.omittedMarker == "[前略]")
    }
}
