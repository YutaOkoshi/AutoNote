import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

func utterance(_ seconds: Double, _ text: String, _ speaker: Speaker = .other) -> Utterance {
    Utterance(start: TimelineTime(seconds: seconds), end: TimelineTime(seconds: seconds + 2), speaker: speaker,
              text: text, isFinal: true)
}

private func document(_ utterances: [Utterance], target: TranslationTarget = .auto, total: Int) -> TranslationDocument {
    TranslationDocument(model: "2b", modelRevision: "rev", target: target, createdAt: Date(timeIntervalSince1970: 0),
                        sourceDigest: TranslationKey.digest(utterances), total: total, complete: false, entries: [])
}

@Suite struct TranscriptTranslationTests {
    let utterances = [
        utterance(0, "We moved about sixty percent of the tenants."),
        Utterance(start: TimelineTime(seconds: 3), speaker: .unknown, text: LiveFeed.pauseMarkerText, isFinal: true),
        utterance(5, "残りも今月末までにいけそうですか。", .me),
        utterance(9, "123"),
        utterance(12, "It slipped twice already, right?"),
        utterance(15, "Put me down."),
        utterance(18, "I'll take it."),
    ]

    @Test func planSkipsMarkersAndLinesWithoutLetters() {
        let plan = TranscriptTranslation.plan(utterances, target: .auto)
        #expect(plan.map(\.index) == [0, 2, 4, 5, 6])
        #expect(plan.map(\.target) == [.ja, .en, .ja, .ja, .ja])
        #expect(TranscriptTranslation.plan(utterances, target: .ja).map(\.index) == [0, 4, 5, 6])
        #expect(TranscriptTranslation.plan(utterances, target: .en).map(\.index) == [2])
    }

    @Test func runTranslatesEveryPlannedLineWithAHistoryOfThree() async throws {
        let fake = FakeTextCompleter()
        let plan = TranscriptTranslation.plan(utterances, target: .auto)
        var doc = document(utterances, total: plan.count)
        var seen: [Int] = []
        let finished = try await TranscriptTranslation.run(&doc, utterances: utterances, plan: plan,
                                                           translator: UtteranceTranslator(completer: fake)) {
            seen.append($0.processed)
            return .proceed
        }
        #expect(finished && doc.complete)
        #expect(seen == [1, 2, 3, 4, 5])
        #expect(doc.entries.map(\.index) == [0, 2, 4, 5, 6])
        #expect(doc.entries[1].text == "EN: 残りも今月末までにいけそうですか。")
        #expect(doc.entries[1].sourceLanguage == .ja && doc.entries[1].targetLanguage == .en)
        #expect(doc.entries[0].sourceHash == TranslationKey.textHash(utterances[0].text))
        let state = fake.snapshot
        #expect(state.stops.allSatisfy { $0 == PlamoPrompt.stopStrings })
        #expect(state.maxTokens[0] == PlamoPrompt.maxTokens(for: utterances[0].text))
        // The fifth prompt carries the three pairs before it, not the first.
        let last = state.prompts[4]
        #expect(!last.contains("sixty percent"))
        #expect(last.contains("残りも今月末") && last.contains("It slipped") && last.contains("Put me down."))
        #expect(last.contains("<|plamo:msg|>JA: Put me down."))
        #expect(last.hasSuffix("I'll take it.<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:key|>form<|plamo:val|>polite<|plamo:msg|>"))
    }

    @Test func suspendKeepsAResumablePartialDocument() async throws {
        let fake = FakeTextCompleter()
        let plan = TranscriptTranslation.plan(utterances, target: .auto)
        var doc = document(utterances, total: plan.count)
        let translator = UtteranceTranslator(completer: fake)
        let first = try await TranscriptTranslation.run(&doc, utterances: utterances, plan: plan, translator: translator) {
            $0.processed == 2 ? .suspend : .proceed
        }
        #expect(!first && !doc.complete)
        #expect(doc.processed == 2 && doc.nextIndex == 3)
        let second = try await TranscriptTranslation.run(&doc, utterances: utterances, plan: plan, translator: translator) { _ in .proceed }
        #expect(second && doc.complete)
        #expect(doc.entries.map(\.index) == [0, 2, 4, 5, 6])
        #expect(fake.snapshot.prompts.count == 5)
        // The resumed run carried the history from the saved entries.
        #expect(fake.snapshot.prompts[2].contains("残りも今月末"))
    }

    @Test func anEmptyOutputCountsAsDoneWithoutAnEntry() async throws {
        let fake = FakeTextCompleter(phrases: ["Put me down.": "  "])
        let plan = TranscriptTranslation.plan(utterances, target: .auto)
        var doc = document(utterances, total: plan.count)
        _ = try await TranscriptTranslation.run(&doc, utterances: utterances, plan: plan,
                                                translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        #expect(doc.processed == 5)
        #expect(doc.entries.map(\.index) == [0, 2, 4, 6])
    }

    @Test func cancellationStopsBetweenUtterances() async throws {
        // The task is cancelled while the second utterance is being translated.
        let fake = FakeTextCompleter(onCall: { n in if n == 2 { withUnsafeCurrentTask { $0?.cancel() } } })
        let plan = TranscriptTranslation.plan(utterances, target: .auto)
        let utterances = utterances
        let task = Task {
            var doc = document(utterances, total: plan.count)
            return try await TranscriptTranslation.run(&doc, utterances: utterances, plan: plan,
                                                       translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fake.snapshot.prompts.count == 2)
    }

    @Test func aPromptTooLongIsRetriedWithFewerHistoryPairs() async throws {
        let history = (0..<3).map { i in
            TranslationPair(source: "Line \(i) " + String(repeating: "x", count: 100), sourceLanguage: .en,
                            translation: "行 \(i)", targetLanguage: .ja)
        }
        let alone = PlamoPrompt.build(text: "Put me down.", source: .en, target: .ja).count
        let withOne = PlamoPrompt.build(text: "Put me down.", source: .en, target: .ja, history: [history[2]]).count
        // Room for the newest pair only: two retries drop the two oldest.
        let fake = FakeTextCompleter(promptLimit: withOne)
        let text = try await UtteranceTranslator(completer: fake)
            .translate("Put me down.", from: .en, to: .ja, history: history)
        #expect(text == "JA: Put me down.")
        let prompts = fake.snapshot.prompts
        #expect(prompts.count == 3)
        #expect(prompts[2].contains("Line 2") && !prompts[2].contains("Line 1"))

        // Too long even without history: left untranslated, no error.
        let tight = FakeTextCompleter(promptLimit: alone - 1)
        #expect(try await UtteranceTranslator(completer: tight)
            .translate("Put me down.", from: .en, to: .ja, history: history) == "")
        #expect(tight.snapshot.prompts.count == 4)
    }

    @Test func aLineTooLongForTheModelDoesNotStopTheRun() async throws {
        let long = String(repeating: "Very long line. ", count: 40)
        let lines = [utterance(0, "Hello there."), utterance(3, long), utterance(6, "See you.")]
        let fake = FakeTextCompleter(promptLimit: 400)
        let plan = TranscriptTranslation.plan(lines, target: .auto)
        var doc = document(lines, total: plan.count)
        let finished = try await TranscriptTranslation.run(&doc, utterances: lines, plan: plan,
                                                           translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        #expect(finished && doc.complete && doc.processed == 3)
        #expect(doc.entries.map(\.index) == [0, 2])
    }

    @Test func aRuntimeErrorIsPassedOn() async {
        let fake = FakeTextCompleter(failOnCall: 2)
        let plan = TranscriptTranslation.plan(utterances, target: .auto)
        var doc = document(utterances, total: plan.count)
        await #expect(throws: FakeTextCompleter.Failure.self) {
            _ = try await TranscriptTranslation.run(&doc, utterances: utterances, plan: plan,
                                                    translator: UtteranceTranslator(completer: fake)) { _ in .proceed }
        }
        #expect(doc.processed == 1 && !doc.complete)
    }
}

@Suite struct TranslationStoreTests {
    let utterances = [utterance(0, "Hello there."), utterance(3, "こんにちは。", .me)]

    @Test func digestChangesWithAnyTextTimeOrSpeaker() {
        let base = TranslationKey.digest(utterances)
        var text = utterances; text[0].text = "Hello."
        var time = utterances; time[1].start = TimelineTime(seconds: 3.5)
        var who = utterances; who[1].speaker = .other
        #expect(Set([base, TranslationKey.digest(text), TranslationKey.digest(time), TranslationKey.digest(who)]).count == 4)
        #expect(TranslationKey.digest(utterances) == base)
    }

    @Test func saveLoadAndStatus() throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = TranslationStore(paths: paths)
        let id = MeetingID(rawValue: "20261114-1000-aaaa")
        let transcript = Transcript(utterances: utterances, engine: "fake", language: .auto)
        #expect(TranslationStatus.of(store.load(id), transcript: transcript) == .none)

        var doc = document(utterances, total: 2)
        doc.processed = 1
        doc.entries = [TranslatedUtterance(index: 0, sourceHash: TranslationKey.textHash("Hello there."),
                                           sourceLanguage: .en, targetLanguage: .ja, text: "こんにちは。")]
        try store.save(doc, for: id)
        #expect(store.load(id) == doc)
        #expect(TranslationStatus.of(store.load(id), transcript: transcript) == .partial(done: 1, total: 2))
        doc.complete = true
        try store.save(doc, for: id)
        #expect(TranslationStatus.of(store.load(id), transcript: transcript) == .complete)

        var redone = transcript
        redone.utterances[0].text = "Hello there, everyone."
        #expect(TranslationStatus.of(store.load(id), transcript: redone) == .stale)
        #expect(MeetingTranslation.make(document: store.load(id), transcript: redone, live: nil).byIndex.isEmpty)
        #expect(MeetingTranslation.make(document: store.load(id), transcript: transcript, live: nil).byIndex[0]?.text == "こんにちは。")
    }

    @Test func entryWhoseLineChangedIsNotShown() {
        var doc = document(utterances, total: 2)
        doc.complete = true
        doc.entries = [TranslatedUtterance(index: 1, sourceHash: TranslationKey.textHash("別の行"),
                                           sourceLanguage: .ja, targetLanguage: .en, text: "Another line")]
        let t = Transcript(utterances: utterances, engine: "fake", language: .auto)
        #expect(MeetingTranslation.make(document: doc, transcript: t, live: nil).byIndex.isEmpty)
    }

    @Test func liveFileIsSeparateAndDeletable() throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = TranslationStore(paths: paths)
        let id = MeetingID(rawValue: "20261114-1000-aaaa")
        let line = LiveTranslatedLine(key: TranslationKey.live(utterances[0]), sourceLanguage: .en, targetLanguage: .ja,
                                      text: "やあ")
        try store.saveLive(LiveTranslationDocument(model: "2b", target: .auto, lines: [line]), for: id)
        #expect(store.liveTranslationFile(id).lastPathComponent == "live-translation.json")
        #expect(store.translationFile(id).deletingLastPathComponent() == paths.transcriptsDirectory(id))
        #expect(MeetingTranslation.make(document: nil, transcript: nil, live: store.loadLive(id)).live[line.key] == line)
        store.deleteLive(id)
        #expect(store.loadLive(id) == nil)
    }

    @Test func liveKeyIsStableForTheSameLine() {
        var u = utterances[0]
        let k = TranslationKey.live(u)
        #expect(TranslationKey.live(u) == k)
        u.text = "Hello there!"
        #expect(TranslationKey.live(u) != k)
    }
}
