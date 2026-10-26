import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

private func part(_ track: Track, _ path: String, _ offset: Double, _ us: [Utterance]) -> TrackTranscription {
    TrackTranscription(file: TrackFile(track: track, relativePath: path, startOffset: .init(seconds: offset), durationSeconds: nil), utterances: us)
}

@Test func dropsEchoesButKeepsBackchannelAndOutsideWindow() {
    let d = EchoDeduplicator(); #expect(d.deduplicate([u(10, .other, "来週の金曜にルミナ茶を発売します", end: 14), u(10.8, .me, "来週の金曜にルミナちゃを発売します", end: 14.5)]).map(\.speaker) == [.other])
    #expect(d.deduplicate([u(30, .other, "それでは価格について説明します", end: 33), u(31, .me, "価格について説明")]).map(\.speaker) == [.other])
    let out = d.deduplicate([u(10, .other, "了解しました", end: 11), u(10.1, .other, "はい"), u(10.2, .me, "はい"), u(20, .me, "了解しました")])
    #expect(out.filter { $0.speaker == .me }.map(\.text) == ["はい", "了解しました"])
    #expect(EchoDeduplicator.normalize("Hello、 World！") == "helloworld"); #expect(EchoDeduplicator.similarity("abcd", "abce") == 0.75)
}

@Test func similarityEdgeCases() {
    #expect(EchoDeduplicator.similarity("", "") == 0)
    #expect(EchoDeduplicator.similarity("abc", "") == 0)
    #expect(EchoDeduplicator.similarity("abc", "abc") == 1)
}

@Test func neverDropsOtherOrUnknown() {
    let out = EchoDeduplicator().deduplicate([u(10, .other, "来週の金曜に発売します", end: 12), u(10, .unknown, "来週の金曜に発売します", end: 12)])
    #expect(out.count == 2)
}

@Test func finalizerKeepsRawAndCleansFinal() {
    let dict = DictionaryFile(terms: [], replacements: [.init(from: "ルミナちゃ", to: "ルミナ茶")], fillers: ["えーと"])
    let parts = [part(.mic, "tracks/mic-000.wav", 0, [u(20, .unknown, "えーと、ルミナちゃの在庫は十分ですか。")])]
    let (raw, final) = TranscriptFinalizer(dictionary: dict, fillerRemoval: true).finalize(parts, source: .live, engine: "whisper.cpp large-v3-turbo", language: .ja)
    #expect(raw.utterances[0].text == "えーと、ルミナちゃの在庫は十分ですか。"); #expect(final.utterances[0].text == "ルミナ茶の在庫は十分ですか。")
    #expect(final.engine == "whisper.cpp large-v3-turbo")
    #expect(TranscriptFinalizer(dictionary: dict, fillerRemoval: false).finalize(parts, source: .live, engine: "e", language: .ja).final.utterances[0].text == "えーと、ルミナ茶の在庫は十分ですか。")
}
