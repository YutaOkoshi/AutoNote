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
        #expect(Set(todos[0].keys) == ["text", "owner"])
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
