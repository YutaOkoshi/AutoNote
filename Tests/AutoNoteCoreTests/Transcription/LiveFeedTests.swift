import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct LiveFeedTests {
    private func makeFeed(
        mic: [Utterance], sys: [Utterance], rules: [Replacement] = [], sysError: FakeError? = nil
    ) throws -> (LiveFeed, FakeLiveTranscriber, FakeLiveTranscriber, URL) {
        let micT = FakeLiveTranscriber(script: mic)
        let sysT = FakeLiveTranscriber(script: sys, startError: sysError)
        let url = try TemporaryDirectory.make().appending(path: "live.json")
        let feed = LiveFeed(transcribers: [.mic: micT, .system: sysT], replacer: Replacer(rules),
                            liveJSON: url, engineName: "Apple DictationTranscriber")
        return (feed, micT, sysT, url)
    }

    private func readTranscript(_ url: URL) throws -> Transcript {
        try AutoNoteJSON.decoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    private func catalog(dictation: [String], models: ModelManager) -> EngineCatalog {
        EngineCatalog(machine: .intel,
                      speech: FakeSpeechCapabilities(speechAvailable: false, speechLocales: [], dictationLocales: dictation),
                      installedModels: { @Sendable in await models.installed().map(\.name) })
    }

    @Test func mergesTwoTracksSortedAndLabelsSpeakers() async throws {
        let (feed, _, _, _) = try makeFeed(mic: [u(5, .unknown, "おはよう")], sys: [u(3, .unknown, "どうも")])
        _ = try await feed.start(language: .ja, hints: [])
        try await waitUntil { await feed.snapshot().count == 2 }
        #expect(await feed.snapshot().map(\.text) == ["どうも", "おはよう"])
        #expect(await feed.snapshot().map(\.speaker) == [.other, .me])
    }

    @Test func sameStartPutsMicFirst() async throws {
        let (feed, _, _, _) = try makeFeed(mic: [u(4, .unknown, "自分")], sys: [u(4, .unknown, "相手")])
        _ = try await feed.start(language: .ja, hints: [])
        try await waitUntil { await feed.snapshot().count == 2 }
        #expect(await feed.snapshot().map(\.speaker) == [.me, .other])
    }

    @Test func partialIsReplacedByFinalWithSameStart() async throws {
        let (feed, _, _, _) = try makeFeed(mic: [partial(5, "おは"), u(5, .unknown, "おはよう")], sys: [])
        _ = try await feed.start(language: .ja, hints: [])
        try await waitUntil { await feed.snapshot().first?.isFinal == true }
        let snap = await feed.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.text == "おはよう")
        #expect(snap.first?.isFinal == true)
    }

    @Test func emptyFinalRemovesPartial() async throws {
        let (feed, _, _, url) = try makeFeed(mic: [partial(5, "えっと"), u(5, .unknown, "")], sys: [])
        _ = try await feed.start(language: .ja, hints: [])
        let transcript = try await feed.finish()
        #expect(await feed.snapshot().isEmpty)
        #expect(transcript.utterances.isEmpty)
        try #expect(readTranscript(url).utterances.isEmpty)
    }

    @Test func replacementOnDisplayOnly() async throws {
        let (feed, _, _, url) = try makeFeed(
            mic: [u(1, .unknown, "オートノートです")], sys: [], rules: [Replacement(from: "オートノート", to: "AutoNote")])
        _ = try await feed.start(language: .ja, hints: [])
        try await waitUntil { await feed.snapshot().count == 1 }
        #expect(await feed.snapshot().map(\.text) == ["AutoNoteです"])
        _ = try await feed.finish()
        try #expect(readTranscript(url).utterances.map(\.text) == ["オートノートです"])
    }

    @Test func streamCarriesReplacedDisplayList() async throws {
        let (feed, _, _, _) = try makeFeed(
            mic: [u(1, .unknown, "オートノートです")], sys: [], rules: [Replacement(from: "オートノート", to: "AutoNote")])
        let stream = try await feed.start(language: .ja, hints: [])
        try await waitUntil { await feed.snapshot().count == 1 }
        _ = try await feed.finish()
        let updates = await collect(stream)
        #expect(updates.last?.map(\.text) == ["AutoNoteです"])
    }

    @Test func pauseMarkerAndBookmarkInOrder() async throws {
        let (feed, _, _, url) = try makeFeed(mic: [u(5, .unknown, "前"), u(22, .unknown, "後")], sys: [])
        _ = try await feed.start(language: .ja, hints: [])
        try await waitUntil { await feed.snapshot().count == 2 }
        await feed.pause(at: TimelineTime(seconds: 10))
        await feed.resume(at: TimelineTime(seconds: 20))
        await feed.bookmark(Bookmark(at: TimelineTime(seconds: 25), note: "重要"))
        let snap = await feed.snapshot()
        #expect(snap.map(\.text) == ["前", "── 一時停止 ──", "後", "── ブックマーク: 重要 ──"])
        #expect(snap.map(LiveFeed.isMarker) == [false, true, false, true])
        #expect(snap[1].start == TimelineTime(seconds: 10))
        #expect(snap[1].speaker == .unknown && snap[1].isFinal)
        #expect(snap[3].start == TimelineTime(seconds: 25))
        _ = try await feed.finish()
        try #expect(readTranscript(url).utterances.map(\.text) == ["前", "後"])
    }

    @Test func bookmarkMarkerTextWithoutNote() {
        #expect(LiveFeed.bookmarkMarkerText(nil) == "── ブックマーク ──")
        #expect(LiveFeed.bookmarkMarkerText("要確認") == "── ブックマーク: 要確認 ──")
        #expect(!LiveFeed.isMarker(u(1, .me, "── 一時停止 ──")))
    }

    @Test func liveJSONWrittenOnFinish() async throws {
        let (feed, _, _, url) = try makeFeed(
            mic: [u(5, .unknown, "確定"), partial(9, "途中")], sys: [u(2, .unknown, "相手側")])
        _ = try await feed.start(language: .ja, hints: ["AutoNote"])
        try await waitUntil { await feed.snapshot().count == 3 }
        let returned = try await feed.finish()
        let saved = try readTranscript(url)
        #expect(saved == returned)
        #expect(saved.engine == "Apple DictationTranscriber")
        #expect(saved.language == .ja)
        #expect(saved.utterances.map(\.text) == ["相手側", "確定"])
        #expect(saved.utterances.map(\.speaker) == [.other, .me])
        #expect(saved.utterances.allSatisfy { $0.isFinal })
    }

    @Test func savesDuringRecordingWhenIntervalElapsed() async throws {
        let micT = FakeLiveTranscriber(script: [u(1, .unknown, "途中保存")])
        let url = try TemporaryDirectory.make().appending(path: "live.json")
        let feed = LiveFeed(transcribers: [.mic: micT], replacer: Replacer([]), liveJSON: url,
                            engineName: "Apple DictationTranscriber", saveInterval: .zero)
        _ = try await feed.start(language: .ja, hints: [])
        try await waitUntil { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        try #expect(readTranscript(url).utterances.map(\.text) == ["途中保存"])
        _ = try await feed.finish()
    }

    @Test func oneTrackFailingKeepsOther() async throws {
        let (feed, _, _, _) = try makeFeed(mic: [u(1, .unknown, "聞こえる")], sys: [], sysError: FakeError(message: "tap failed"))
        _ = try await feed.start(language: .ja, hints: [])
        #expect(await feed.failures[.system] != nil)
        #expect(await feed.failures[.mic] == nil)
        try await waitUntil { await feed.snapshot().count == 1 }
        #expect(await feed.snapshot().map(\.text) == ["聞こえる"])
    }

    @Test func bothTracksFailingThrows() async throws {
        let micT = FakeLiveTranscriber(script: [], startError: FakeError(message: "mic broke"))
        let sysT = FakeLiveTranscriber(script: [], startError: FakeError(message: "sys broke"))
        let feed = LiveFeed(transcribers: [.mic: micT, .system: sysT], replacer: Replacer([]),
                            liveJSON: try TemporaryDirectory.make().appending(path: "live.json"),
                            engineName: "Apple DictationTranscriber")
        await #expect {
            _ = try await feed.start(language: .ja, hints: [])
        } throws: { error in
            guard case TranscriptionError.engineUnavailable = error else { return false }
            return true
        }
        #expect(await feed.failures.count == 2)
    }

    @Test func makeResolvesLiveEngineFromSettings() async throws {
        let models = ModelManager(directory: try TemporaryDirectory.make(), catalog: [])
        let cat = catalog(dictation: ["ja-JP"], models: models)
        let factory = TranscriberFactory(models: models, machine: .intel)
        let dict = DictionaryFile(terms: [], replacements: [], fillers: [])
        let url = try TemporaryDirectory.make().appending(path: "live.json")

        let byDefault = try await LiveFeed.make(settings: Settings(), catalog: cat, factory: factory, dictionary: dict, liveJSON: url)
        #expect(byDefault.engineName == "Apple DictationTranscriber")

        var speech = Settings()
        speech.liveEngine = "speech"
        let fallback = try await LiveFeed.make(settings: speech, catalog: cat, factory: factory, dictionary: dict, liveJSON: url)
        #expect(fallback.engineName == "Apple DictationTranscriber")
    }

    @Test func makeThrowsWhenNoLiveEngine() async throws {
        let models = ModelManager(directory: try TemporaryDirectory.make(), catalog: [])
        let cat = catalog(dictation: [], models: models)
        let factory = TranscriberFactory(models: models, machine: .intel)
        let dict = DictionaryFile(terms: [], replacements: [], fillers: [])
        let url = try TemporaryDirectory.make().appending(path: "live.json")
        await #expect {
            _ = try await LiveFeed.make(settings: Settings(), catalog: cat, factory: factory, dictionary: dict, liveJSON: url)
        } throws: { error in
            guard case TranscriptionError.engineUnavailable = error else { return false }
            return true
        }
    }

    @Test func feedRoutesByTrack() async throws {
        let (feed, mic, sys, _) = try makeFeed(mic: [], sys: [])
        _ = try await feed.start(language: .ja, hints: ["用語"])
        await feed.feed(chunk(silence(0.1), at: 0, track: .mic))
        #expect(await mic.fedChunks.count == 1)
        #expect(await sys.fedChunks.isEmpty)
        #expect(await mic.startedWith?.1 == ["用語"])
    }
}
