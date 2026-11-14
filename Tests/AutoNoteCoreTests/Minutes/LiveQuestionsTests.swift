import Foundation
import Synchronization
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct LiveQuestionListTests {
    private func list(_ items: [LiveQuestion]) -> LiveQuestionList { LiveQuestionList(items: items) }
    private func q(_ id: String, _ text: String, asked: Bool = false, by: LiveQuestionMarker? = nil) -> LiveQuestion {
        LiveQuestion(id: id, text: text, asked: asked, askedBy: by)
    }

    @Test func encodesSnakeCaseAndReadsMissingFieldsAsUnasked() throws {
        let l = list([q("q1", "会場のキャパシティ", asked: true, by: .model)])
        let object = try #require(try JSONSerialization.jsonObject(with: try AutoNoteJSON.encoder().encode(l)) as? [String: Any])
        let item = try #require((object["items"] as? [[String: Any]])?.first)
        #expect(Set(item.keys) == ["id", "text", "asked", "asked_by"])
        #expect(item["asked_by"] as? String == "model")
        let old = #"{"items":[{"id":"a","text":"録画の公開範囲"}]}"#
        #expect(try AutoNoteJSON.decoder().decode(LiveQuestionList.self, from: Data(old.utf8)) == list([q("a", "録画の公開範囲")]))
    }

    @Test func addTrimsCapsAndRejectsBlanksAndOverflow() {
        var l = LiveQuestionList.empty
        let added = [l.add("  入館証の締め切り \n", id: "a"), l.add("   ", id: "b"), l.add(String(repeating: "あ", count: 250), id: "c")]
        #expect(added == [true, false, true])
        #expect(l.items.map(\.id) == ["a", "c"])
        #expect(l.items[0].text == "入館証の締め切り" && !l.items[0].asked && l.items[0].askedBy == nil)
        #expect(l.items[1].text.count == LiveQuestionList.textLimit)
        for n in 2..<LiveQuestionList.limit { l.add("問い \(n)", id: "n\(n)") }
        #expect(l.items.count == 30 && !l.canAdd)
        let over = l.add("31 件目", id: "over")
        #expect(!over)
        #expect(l.items.count == 30)
        #expect(LiveQuestionList.limit == 30 && LiveQuestionList.textLimit == 200)
    }

    @Test func userToggleRemoveAndRename() {
        var l = list([q("a", "一"), q("b", "二", asked: true, by: .model)])
        l.setAsked("a", true)
        l.setAsked("b", false)
        #expect(l.items == [q("a", "一", asked: true, by: .user), q("b", "二", asked: false, by: .user)])
        l.rename("a", to: "  一の改  ")
        l.rename("b", to: "   ")                   // blank: unchanged
        #expect(l.items.map(\.text) == ["一の改", "二"])
        #expect(l.items[0].asked && l.items[0].askedBy == .user)
        l.remove("a")
        l.remove("zzz")
        #expect(l.items.map(\.id) == ["b"])
    }

    /// Only undecided items reach the model: not asked and not set by hand.
    @Test func pendingForModelSkipsAskedAndUserSet() {
        let l = list([q("a", "一"), q("b", "二", asked: true, by: .model), q("c", "三", asked: false, by: .user),
                      q("d", "四", asked: true, by: .user), q("e", "五")])
        #expect(l.pendingForModel == [LiveQuestionPrompt(id: "a", text: "一"), LiveQuestionPrompt(id: "e", text: "五")])
        #expect(l.askedCount == 2)
    }

    /// The model only ever marks asked: never unmarks, never overrides the user, ignores unknown ids.
    @Test func markAskedByModel() {
        var l = list([q("a", "一"), q("b", "二", asked: true, by: .model), q("c", "三", asked: false, by: .user), q("d", "四")])
        l.markAskedByModel(["a", "c", "zzz"])
        #expect(l.items == [q("a", "一", asked: true, by: .model), q("b", "二", asked: true, by: .model),
                            q("c", "三", asked: false, by: .user), q("d", "四")])
    }

    @Test func appendingKeepsIDsUniqueAndTheLimit() {
        var l = list([q("a", "一")])
        var n = 0
        l.append(contentsOf: [q("a", "下書きの一"), q("x", "下書きの二")]) { n += 1; return "new\(n)" }
        #expect(l.items.map(\.id) == ["a", "new1", "x"])
        #expect(l.items.map(\.text) == ["一", "下書きの一", "下書きの二"])
        var full = LiveQuestionList(items: (0..<29).map { q("f\($0)", "問い \($0)") })
        full.append(contentsOf: [q("y", "30"), q("z", "31")]) { "unused" }
        #expect(full.items.count == 30 && full.items.last?.id == "y")
    }

    @Test func applyingEdits() {
        var l = LiveQuestionList.empty
        l.apply(.add("一"), makeID: { "a" })
        l.apply(.add("二"), makeID: { "a" })        // collision → a fresh id is drawn again
        #expect(l.items.count == 2 && Set(l.items.map(\.id)).count == 2)
        let second = l.items[1].id
        l.apply(.setAsked(id: second, true), makeID: { "" })
        l.apply(.rename(id: "a", "一'"), makeID: { "" })
        l.apply(.remove(id: "a"), makeID: { "" })
        #expect(l.items == [q(second, "二", asked: true, by: .user)])
    }
}

@Suite struct LiveQuestionsRepositoryTests {
    private let id = MeetingID(rawValue: "20261114-1000-0001")

    private func paths() throws -> AppPaths {
        AppPaths(root: try TemporaryDirectory.make())
    }

    private func counter() -> @Sendable () -> String {
        let n = Counter()
        return { "q\(n.next())" }
    }

    @Test func filesSitNextToLiveSummaryAndInTheDataRoot() throws {
        let p = try paths()
        #expect(p.questionsFile(id).deletingLastPathComponent() == p.liveSummaryFile(id).deletingLastPathComponent())
        #expect(p.questionsFile(id).lastPathComponent == "questions.json")
        #expect(p.pendingQuestionsFile == p.root.appending(path: "pending-questions.json"))
    }

    @Test func editsAreSavedAndReadBack() async throws {
        let p = try paths()
        let repo = LiveQuestionsRepository(storage: LiveQuestionsFileStorage(paths: p), makeID: counter())
        await repo.apply(.add("会場のキャパシティ"), to: .meeting(id))
        await repo.apply(.add("入館証の締め切り"), to: .meeting(id))
        await repo.apply(.setAsked(id: "q1", true), to: .meeting(id))
        let fresh = LiveQuestionsRepository(storage: LiveQuestionsFileStorage(paths: p), makeID: counter())
        #expect(await fresh.list(.meeting(id)) == [LiveQuestion(id: "q1", text: "会場のキャパシティ", asked: true, askedBy: .user),
                                                   LiveQuestion(id: "q2", text: "入館証の締め切り", asked: false, askedBy: nil)])
        #expect(FileManager.default.fileExists(atPath: p.questionsFile(id).path))
        #expect(await fresh.list(.draft).isEmpty)
    }

    /// Starting a recording moves the draft into that meeting and empties the draft.
    @Test func adoptDraftMovesItIntoTheMeeting() async throws {
        let p = try paths()
        let repo = LiveQuestionsRepository(storage: LiveQuestionsFileStorage(paths: p), makeID: counter())
        await repo.apply(.add("当日の受付は誰か"), to: .draft)
        await repo.apply(.setAsked(id: "q1", true), to: .draft)
        await repo.apply(.add("録画の公開範囲"), to: .draft)
        await repo.adoptDraft(into: id)
        #expect(await repo.list(.draft).isEmpty)
        #expect(await repo.list(.meeting(id)).map(\.text) == ["当日の受付は誰か", "録画の公開範囲"])
        #expect(await repo.list(.meeting(id)).first?.askedBy == .user)
        let draftData = try Data(contentsOf: p.pendingQuestionsFile)
        #expect(try AutoNoteJSON.decoder().decode(LiveQuestionList.self, from: draftData).items.isEmpty)
        // An empty draft writes no file for the next meeting.
        let other = MeetingID(rawValue: "20261114-1100-0002")
        await repo.adoptDraft(into: other)
        #expect(!FileManager.default.fileExists(atPath: p.questionsFile(other).path))
    }

    /// The model's result is applied to the file as it is now: items added, removed or changed by hand meanwhile stay.
    @Test func modelMarksReReadTheFile() async throws {
        let p = try paths()
        let repo = LiveQuestionsRepository(storage: LiveQuestionsFileStorage(paths: p), makeID: counter())
        for t in ["一", "二", "三"] { await repo.apply(.add(t), to: .meeting(id)) }
        let pending = await repo.pendingForModel(id)
        #expect(pending.map(\.id) == ["q1", "q2", "q3"])
        // While the call is in flight: q2 is unchecked by hand, q3 is removed, q4 is added.
        await repo.apply(.setAsked(id: "q2", false), to: .meeting(id))
        await repo.apply(.remove(id: "q3"), to: .meeting(id))
        await repo.apply(.add("四"), to: .meeting(id))
        await repo.markAskedByModel(["q1", "q2", "q3"], in: id)
        #expect(await repo.list(.meeting(id)) == [
            LiveQuestion(id: "q1", text: "一", asked: true, askedBy: .model),
            LiveQuestion(id: "q2", text: "二", asked: false, askedBy: .user),
            LiveQuestion(id: "q4", text: "四", asked: false, askedBy: nil)])
        #expect(await repo.pendingForModel(id) == [LiveQuestionPrompt(id: "q4", text: "四")])
    }

    @Test func updatesCarryEveryChange() async throws {
        let repo = LiveQuestionsRepository(storage: InMemoryLiveQuestionsStorage(), makeID: counter())
        var it = await repo.updates().makeAsyncIterator()
        await repo.apply(.add("一"), to: .draft)
        #expect(await it.next() == LiveQuestionsUpdate(scope: .draft, items: [LiveQuestion(id: "q1", text: "一", asked: false, askedBy: nil)]))
        await repo.adoptDraft(into: id)
        let a = await it.next(), b = await it.next()
        #expect(Set([a?.scope, b?.scope].compactMap { $0 }) == [.draft, .meeting(id)])
        await repo.markAskedByModel(["q1"], in: id)
        #expect(await it.next()?.items.first?.askedBy == .model)
    }

    @Test func corruptFileReadsAsEmpty() async throws {
        let p = try paths()
        try FileManager.default.createDirectory(at: p.transcriptsDirectory(id), withIntermediateDirectories: true)
        try Data("{oops".utf8).write(to: p.questionsFile(id))
        let repo = LiveQuestionsRepository(storage: LiveQuestionsFileStorage(paths: p), makeID: counter())
        #expect(await repo.list(.meeting(id)).isEmpty)
        #expect(await repo.pendingForModel(id).isEmpty)
    }

    @Test func randomIDsAreShortAndDistinct() {
        let ids = (0..<200).map { _ in LiveQuestionsRepository.randomID() }
        #expect(Set(ids).count == 200)
        #expect(ids.allSatisfy { $0.count == 8 })
    }
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}
