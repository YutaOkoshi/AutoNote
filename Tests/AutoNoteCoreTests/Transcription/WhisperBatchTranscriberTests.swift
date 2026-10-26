import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct WhisperBatchTranscriberTests {
    private func transcribe(
        _ core: FakeWhisperCore, seconds: Double = 4, language: Language = .ja, hints: [String] = [],
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> [Utterance] {
        try await WhisperBatchTranscriber(core: core, gate: BatchGate())
            .transcribe(file: try wavFile(seconds: seconds), language: language, hints: hints, progress: progress)
    }

    @Test func segmentsBecomeFinalUtterances() async throws {
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "こんにちは"), .init(start: 2, end: 4, text: "よろしく")])
        let u = try await transcribe(core)
        #expect(u.map(\.start.seconds) == [0, 2])
        #expect(u.map { $0.end?.seconds } == [2, 4])
        #expect(u.map(\.text) == ["こんにちは", "よろしく"])
        #expect(u.allSatisfy { $0.isFinal && $0.speaker == .unknown })
    }

    @Test func progressIsMonotonicAndEndsAtOne() async throws {
        let core = FakeWhisperCore(segments: [
            .init(start: 0, end: 2, text: "一"), .init(start: 2, end: 4, text: "二"), .init(start: 4, end: 6, text: "三"),
        ])
        let box = ProgressBox()
        _ = try await transcribe(core, seconds: 6, progress: { box.append($0) })
        let values = box.values
        #expect(values.count >= 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values.last == 1.0)
    }

    @Test func cancellationStopsAndThrows() async throws {
        let core = FakeWhisperCore(
            segments: (0..<20).map { .init(start: Double($0), end: Double($0 + 1), text: "\($0)") }, delay: .milliseconds(100))
        let file = try wavFile(seconds: 20)
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: BatchGate())
                .transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await waitUntil { core.emittedCount >= 1 }
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        #expect(core.runCount == 1)
        #expect(core.emittedCount < 20)
    }

    @Test func pauseAbortsAndResumesFromLastSegmentEnd() async throws {
        // 1 つ目が出た後に pause → 2 つ目（2–4）の境界で .aborted。resume 後の 2 本目は offset 4 から 3 つ目だけを出す
        let gate = BatchGate()
        let core = FakeWhisperCore(
            segments: [.init(start: 0, end: 2, text: "一"), .init(start: 2, end: 4, text: "二"), .init(start: 4, end: 6, text: "三")],
            delay: .milliseconds(200))
        let file = try wavFile(seconds: 6)
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate).transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await waitUntil { core.emittedCount >= 1 }
        await gate.pause()
        #expect(gate.isPaused)
        try await waitUntil { core.emittedCount >= 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(core.runCount == 1)   // 一時停止中は 2 本目を始めない
        await gate.resume()
        #expect(!gate.isPaused)
        let u = try await t.value
        #expect(core.requests.map(\.offsetSeconds) == [0, 4])
        #expect(u.map(\.text) == ["一", "二", "三"])
    }

    @Test func cancellationWhilePausedThrowsPromptly() async throws {
        let gate = BatchGate()
        await gate.pause()
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "一")])
        let file = try wavFile(seconds: 2)
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate).transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ContinuousClock.now
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(gate.isPaused)
        #expect(core.runCount == 0)
    }

    @Test func pausedGateHoldsTheFirstRun() async throws {
        let gate = BatchGate()
        await gate.pause()
        let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "一")])
        let file = try wavFile(seconds: 2)
        let t = Task {
            try await WhisperBatchTranscriber(core: core, gate: gate).transcribe(file: file, language: .ja, hints: [], progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(core.runCount == 0)
        await gate.resume()
        #expect(try await t.value.map(\.text) == ["一"])
    }

    @Test func repetitionFilterIsApplied() async throws {
        let core = FakeWhisperCore(segments: [
            .init(start: 0, end: 2, text: "了解です"), .init(start: 2, end: 4, text: "了解です。"),
            .init(start: 4, end: 6, text: "ご視聴ありがとうございました"),
        ])
        #expect(try await transcribe(core, seconds: 6).map(\.text) == ["了解です"])
    }

    @Test func hintsBecomePrompt() async throws {
        let core = FakeWhisperCore(segments: [])
        _ = try await transcribe(core, hints: ["所沢", "Kubernetes"])
        #expect(core.requests.first?.prompt == "所沢、Kubernetes")
    }

    @Test func noHintsNoPrompt() async throws {
        let core = FakeWhisperCore(segments: [])
        _ = try await transcribe(core)
        #expect(core.requests.count == 1)
        #expect(core.requests[0].prompt == nil)
    }

    @Test func languageIsForwarded() async throws {
        let core = FakeWhisperCore(segments: [])
        _ = try await transcribe(core, language: .en)
        #expect(core.requests[0].language == .en)
        #expect(core.requests[0].mode == .batch)
        #expect(core.requests[0].offsetSeconds == 0)
        #expect(core.requests[0].samples.count == 4 * 16_000)
    }
}
