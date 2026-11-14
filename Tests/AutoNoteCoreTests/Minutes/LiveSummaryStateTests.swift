import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct LiveSummaryStateTests {
    private func tempPaths() throws -> AppPaths {
        let dir = FileManager.default.temporaryDirectory.appending(path: "LiveSummaryStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppPaths(root: dir)
    }

    private let id = MeetingID(rawValue: "20261028-1000-0001")

    @Test func encodesSnakeCaseKeys() throws {
        let s = LiveSummaryState(now: "予算の話", decisions: ["A"], todos: [.init(text: "送る", owner: "佐藤")],
                                 consumedThrough: 12, updatedAt: Samples.start)
        let data = try AutoNoteJSON.encoder().encode(s)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["now", "decisions", "todos", "consumed_through", "updated_at"])
        let todos = try #require(object["todos"] as? [[String: Any]])
        #expect(Set(todos[0].keys) == ["text", "owner", "side"])
        #expect(todos[0]["side"] as? String == "unknown")
    }

    @Test func todoSideRoundTripsAsSelfOtherUnknown() throws {
        let s = LiveSummaryState(now: "", decisions: [],
                                 todos: [.init(text: "a", owner: nil, side: .me), .init(text: "b", owner: nil, side: .other),
                                         .init(text: "c", owner: nil, side: .unknown)],
                                 consumedThrough: 1, updatedAt: nil)
        let data = try AutoNoteJSON.encoder().encode(s)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sides = try #require(object["todos"] as? [[String: Any]]).compactMap { $0["side"] as? String }
        #expect(sides == ["self", "other", "unknown"])
        #expect(try AutoNoteJSON.decoder().decode(LiveSummaryState.self, from: data) == s)
    }

    /// A `live-summary.json` written before `side` existed reads every todo as `unknown`; an unknown value too.
    @Test func oldStateWithoutSideReadsAsUnknown() throws {
        let json = #"{"now":"予算","decisions":["A"],"todos":[{"text":"送る","owner":"佐藤"},{"text":"x","owner":null,"side":"later"}],"consumed_through":12}"#
        let s = try AutoNoteJSON.decoder().decode(LiveSummaryState.self, from: Data(json.utf8))
        #expect(s.todos == [.init(text: "送る", owner: "佐藤", side: .unknown), .init(text: "x", owner: nil, side: .unknown)])
    }

    @Test func outputReadsAskedQuestionIDs() throws {
        let json = #"{"now":"x","decisions":[],"todos":[{"text":"送る","owner":null,"side":"self"}],"asked_question_ids":["q1","q2"]}"#
        let out = try AutoNoteJSON.decoder().decode(LiveSummaryOutput.self, from: Data(json.utf8))
        #expect(out.askedQuestionIDs == ["q1", "q2"])
        #expect(out.todos == [.init(text: "送る", owner: nil, side: .me)])
        // Missing (an older fixture) is empty.
        let old = try AutoNoteJSON.decoder().decode(LiveSummaryOutput.self, from: Data(#"{"now":"","decisions":[],"todos":[]}"#.utf8))
        #expect(old.askedQuestionIDs.isEmpty)
        let encoded = try #require(try JSONSerialization.jsonObject(with: try AutoNoteJSON.encoder().encode(out)) as? [String: Any])
        #expect(encoded["asked_question_ids"] as? [String] == ["q1", "q2"])
    }

    /// A speaker label is not an owner (the side already says which side): 自分 / 相手 / 不明 and the side values drop to nil.
    @Test func applyingDropsSpeakerLabelOwners() {
        let labels = ["自分", "相手", "不明", "self", "other", "unknown", "me", " 相手 ", "Self"]
        let out = LiveSummaryOutput(now: "x", decisions: [],
                                    todos: labels.enumerated().map { .init(text: "t\($0.offset)", owner: $0.element, side: .other) }
                                        + [.init(text: "名前あり", owner: "佐藤", side: .other),
                                           .init(text: "役割名", owner: "広報担当", side: .me)])
        let s = LiveSummaryState.empty.applying(out, consumedThrough: 1, at: Samples.start)
        #expect(s.todos.prefix(labels.count).allSatisfy { $0.owner == nil })
        #expect(s.todos.suffix(2).map(\.owner) == ["佐藤", "広報担当"])
    }

    @Test func applyingKeepsTheSide() {
        let out = LiveSummaryOutput(now: "x", decisions: [],
                                    todos: [.init(text: " 送る ", owner: nil, side: .other), .init(text: "送る", owner: nil, side: .me)])
        let s = LiveSummaryState.empty.applying(out, consumedThrough: 1, at: Samples.start)
        #expect(s.todos == [.init(text: "送る", owner: nil, side: .other)])
    }

    @Test func applyingKeepsNewestFifty() {
        let out = LiveSummaryOutput(now: "x", decisions: (0..<60).map { "d\($0)" },
                                    todos: (0..<60).map { LiveSummaryTodo(text: "t\($0)", owner: nil) })
        let s = LiveSummaryState.empty.applying(out, consumedThrough: 1, at: Samples.start)
        #expect(s.decisions == (10..<60).map { "d\($0)" })
        #expect(s.todos == (10..<60).map { LiveSummaryTodo(text: "t\($0)", owner: nil) })
        #expect(LiveSummaryState.listLimit == 50 && LiveSummaryState.nowLimit == 60)
    }

    @Test func applyingCleansModelOutput() {
        let out = LiveSummaryOutput(now: "  " + String(repeating: "話", count: 70) + " ",
                                    decisions: ["A", " ", "A", "B "], todos: [.init(text: "送る", owner: " "), .init(text: "", owner: "佐藤")])
        let s = LiveSummaryState.empty.applying(out, consumedThrough: 40, at: Samples.start)
        #expect(s.now.count == 60 && s.decisions == ["A", "B"] && s.todos == [.init(text: "送る", owner: nil)])
        #expect(s.consumedThrough == 40 && s.updatedAt == Samples.start)
    }

    @Test func consumedThroughNeverGoesBack() {
        var base = LiveSummaryState.empty
        base.consumedThrough = 100
        let s = base.applying(LiveSummaryOutput(now: "", decisions: [], todos: []), consumedThrough: 90, at: Samples.start)
        #expect(s.consumedThrough == 100)
    }

    @Test func emptyIsBlank() {
        let e = LiveSummaryState.empty
        #expect(e.now == "" && e.decisions.isEmpty && e.todos.isEmpty && e.consumedThrough == 0 && e.updatedAt == nil)
        #expect(e.output == LiveSummaryOutput(now: "", decisions: [], todos: []))
    }

    @Test func storeRoundTripsNextToLiveJSON() throws {
        let paths = try tempPaths()
        let store = LiveSummaryStore(paths: paths)
        let s = LiveSummaryState(now: "予算", decisions: ["A"], todos: [.init(text: "送る", owner: nil)],
                                 consumedThrough: 33.5, updatedAt: Samples.start)
        try store.save(s, for: id)
        #expect(paths.liveSummaryFile(id).lastPathComponent == "live-summary.json")
        #expect(paths.liveSummaryFile(id).deletingLastPathComponent().standardizedFileURL
                == paths.transcriptFile(id, .live).deletingLastPathComponent().standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: paths.liveSummaryFile(id).path))
        #expect(try store.load(id) == s)
    }

    @Test func storeMissingIsNilAndCorruptThrows() throws {
        let paths = try tempPaths()
        let store = LiveSummaryStore(paths: paths)
        #expect(try store.load(id) == nil)
        try FileManager.default.createDirectory(at: paths.transcriptsDirectory(id), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: paths.liveSummaryFile(id))
        #expect(throws: (any Error).self) { try store.load(id) }
    }
}

@Suite struct LiveSummaryStepTests {
    @Test func stepKeepsOnlyAskedIDsThatWereSent() async throws {
        let r = LiveSummaryRequest(previous: .empty, utterances: [], consumedThrough: 5,
                                   questions: [.init(id: "q1", text: "一"), .init(id: "q2", text: "二")])
        let out = LiveSummaryOutput(now: "x", decisions: [], todos: [], askedQuestionIDs: ["q2", "zzz", "q2"])
        let result = try await LiveSummaryStep.run(r, summarizer: ScriptedLiveSummarizer(results: [.success(out)]), now: Samples.start)
        #expect(result.askedQuestionIDs == ["q2"])
        #expect(result.state.now == "x" && result.state.consumedThrough == 5)
    }

    /// The fake marks the first undecided question it was sent, so a second call shows what was (not) sent.
    @Test func fakeMarksTheFirstQuestionSent() async throws {
        let fake = FakeLiveSummarizer()
        var r = LiveSummaryRequest(previous: .empty, utterances: [], consumedThrough: 5)
        #expect(try await fake.summarize(r).askedQuestionIDs.isEmpty)
        r.questions = [.init(id: "q2", text: "二"), .init(id: "q3", text: "三")]
        let out = try await fake.summarize(r)
        #expect(out.askedQuestionIDs == ["q2"])
        #expect(out.todos.map(\.side) == [.me])
    }
}
