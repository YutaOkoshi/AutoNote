import AutoNoteCore
import Foundation
import Testing

@Suite struct DevLiveSummaryArgumentsTests {
    @Test func parsesLiveStateAndClaude() throws {
        let a = try DevLiveSummaryArguments.parse(["l.json", "--state", "s.json", "--claude"])
        #expect(a.live.lastPathComponent == "l.json")
        #expect(a.state?.lastPathComponent == "s.json")
        #expect(a.useClaude)

        let plain = try DevLiveSummaryArguments.parse(["l.json"])
        #expect(plain.live.lastPathComponent == "l.json")
        #expect(plain.state == nil)
        #expect(!plain.useClaude)
        #expect(plain.questions == nil)

        let q = try DevLiveSummaryArguments.parse(["--questions", "q.json", "l.json"])
        #expect(q.questions?.lastPathComponent == "q.json" && q.live.lastPathComponent == "l.json")
        #expect(DevLiveSummaryArguments.usage.contains("[--questions <questions.json>]"))
    }

    /// The printed line is the state plus, with `--questions`, the ids sent and found asked and the updated list.
    @Test func outputLineFlattensTheState() throws {
        let state = LiveSummaryState(now: "x", decisions: ["A"], todos: [.init(text: "送る", owner: nil, side: .me)],
                                     consumedThrough: 85, updatedAt: nil)
        let plain = try #require(try JSONSerialization.jsonObject(with: try DevLiveSummaryLine(state: state).encoded()) as? [String: Any])
        #expect(Set(plain.keys) == ["now", "decisions", "todos", "consumed_through"])
        let line = DevLiveSummaryLine(state: state, sentQuestionIDs: ["q1"], askedQuestionIDs: ["q1"],
                                      questions: LiveQuestionList(items: [.init(id: "q1", text: "一", asked: true, askedBy: .model)]))
        let object = try #require(try JSONSerialization.jsonObject(with: try line.encoded()) as? [String: Any])
        #expect(Set(object.keys) == ["now", "decisions", "todos", "consumed_through",
                                     "sent_question_ids", "asked_question_ids", "questions"])
        #expect(object["asked_question_ids"] as? [String] == ["q1"])
        // The `questions` value is a questions file again (it can be passed back with --questions).
        let questions = try JSONSerialization.data(withJSONObject: try #require(object["questions"]))
        #expect(try AutoNoteJSON.decoder().decode(LiveQuestionList.self, from: questions).items.first?.askedBy == .model)
        // And the line still reads as a state (for --state).
        #expect(try AutoNoteJSON.decoder().decode(LiveSummaryState.self, from: try line.encoded()) == state)
    }

    @Test func rejectsBadArguments() {
        for args in [[], ["a", "b"], ["l.json", "--state"], ["l.json", "--bogus"], ["l.json", "--questions"]] {
            #expect(throws: DevLiveSummaryArguments.ParseError.self) {
                try DevLiveSummaryArguments.parse(args)
            }
        }
    }
}
