import AutoNoteTestSupport
import Foundation
import Synchronization
import Testing
@testable import AutoNoteCore

private let realModel = ProcessInfo.processInfo.environment["AUTONOTE_TEST_WHISPER_MODEL"]

@Suite struct WhisperContextTests {
    @Test func missingModelThrows() {
        let path = "/nonexistent/autonote/ggml-missing.bin"
        #expect(throws: TranscriptionError.modelMissing(path)) {
            _ = try WhisperContext(modelURL: URL(fileURLWithPath: path), machine: .intel, threads: 1)
        }
    }

    @Test func quietLoggingKeepsSystemInfo() {
        WhisperRuntime.installQuietLogging()
        WhisperRuntime.installQuietLogging()   // 2 回目は何もしない
        #expect(!WhisperRuntime.systemInfo().isEmpty)
    }

    @Test func batchThreadsAreBounded() {
        #expect((1...4).contains(WhisperContext.batchThreads))
    }

    // 実モデル。環境変数 AUTONOTE_TEST_WHISPER_MODEL が ggml の実在パスのときだけ
    @Test(.enabled(if: realModel != nil))
    func realCoreHandlesSilence() async throws {
        let core = try WhisperContext(modelURL: URL(fileURLWithPath: realModel!), machine: .current(), threads: 2)
        let request = WhisperRunRequest(
            samples: PCMAudio.floats(silence(3)), offsetSeconds: 0, language: .ja, prompt: nil, mode: .batch)
        let outcome = try await core.run(request, onSegment: { _, _ in }, onProgress: { _ in }, shouldAbort: { false })
        #expect(outcome == .completed)
    }

    @Test(.enabled(if: realModel != nil))
    func realCoreAbortsWhenAsked() async throws {
        let core = try WhisperContext(modelURL: URL(fileURLWithPath: realModel!), machine: .current(), threads: 2)
        let request = WhisperRunRequest(samples: PCMAudio.floats(tone(10)), offsetSeconds: 0, language: .en, prompt: nil, mode: .batch)
        let outcome = try await core.run(request, onSegment: { _, _ in }, onProgress: { _ in }, shouldAbort: { true })
        #expect(outcome == .aborted)
    }

    /// live モードのトークンは文字の途中で切れない（バイト単位の BPE を UTF-8 の境界でつなぐ）。
    @Test(.enabled(if: realModel != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
    func realLiveTokensAreWholeCharacters() async throws {
        let dir = try TemporaryDirectory.make()
        let aiff = dir.appending(path: "ja.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Kyoko", "-o", aiff.path, "東京都庁で会議を始めます。議題は予算です。"]
        try say.run(); say.waitUntilExit()
        try #require(say.terminationStatus == 0)
        let core = try WhisperContext(modelURL: URL(fileURLWithPath: realModel!), machine: .current(), threads: 2)
        let tokens = Mutex<[TimedToken]>([])
        let request = WhisperRunRequest(
            samples: PCMAudio.floats(try PCMAudio.readMono16k(aiff)), offsetSeconds: 0, language: .ja, prompt: nil, mode: .live)
        let outcome = try await core.run(request, onSegment: { _, t in tokens.withLock { $0 += t } }, onProgress: { _ in }, shouldAbort: { false })
        #expect(outcome == .completed)
        let all = tokens.withLock { $0 }
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { !$0.text.contains("\u{FFFD}") && $0.start <= $0.end })
    }

    /// `offset_ms` を使うと、セグメントの時刻は渡した音声の先頭からの秒になる（オフセットを含む）。
    @Test(.enabled(if: realModel != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
    func realCoreSegmentsAreAbsoluteWithOffset() async throws {
        let dir = try TemporaryDirectory.make()
        let aiff = dir.appending(path: "speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "Hello. This is a short test of the transcription system. Thank you."]
        try say.run(); say.waitUntilExit()
        try #require(say.terminationStatus == 0)
        let samples = silence(5) + (try PCMAudio.readMono16k(aiff))
        let core = try WhisperContext(modelURL: URL(fileURLWithPath: realModel!), machine: .current(), threads: 2)
        let found = Mutex<[WhisperSegment]>([])
        let request = WhisperRunRequest(samples: PCMAudio.floats(samples), offsetSeconds: 5, language: .en, prompt: "transcription", mode: .batch)
        let outcome = try await core.run(request, onSegment: { s, _ in found.withLock { $0.append(s) } }, onProgress: { _ in }, shouldAbort: { false })
        #expect(outcome == .completed)
        let segments = found.withLock { $0 }
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.start >= 4.9 && $0.end <= Double(samples.count) / 16_000 + 0.5 })
        #expect(segments.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("test"))
    }
}
