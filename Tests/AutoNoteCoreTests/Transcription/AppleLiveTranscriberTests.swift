import AVFoundation
@preconcurrency import Speech
import Synchronization
import Testing
@testable import AutoNoteCore

/// Passes buffers through, failing on the listed calls (1-based) and adding `flushFrames` frames on flush.
final class FakeAnalyzerConverter: AnalyzerAudioConverting, @unchecked Sendable {
    struct Failed: Error {}
    private let failOn: Set<Int>
    private let flushFrames: Int
    private(set) var calls = 0
    private(set) var flushes = 0

    init(failOn: Set<Int> = [], flushFrames: Int = 0) { self.failOn = failOn; self.flushFrames = flushFrames }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        calls += 1
        if failOn.contains(calls) { throw Failed() }
        return buffer
    }

    func flush() throws -> AVAudioPCMBuffer? {
        flushes += 1
        return flushFrames > 0 ? AppleAudioBuffers.pcmBuffer(chunk(silence(Double(flushFrames) / 16_000), at: 0)) : nil
    }
}

final class Flag: Sendable { let value = Mutex(false) }

/// Counts what the transcriber hands to the analyzer.
final class InputCounter: Sendable {
    private final class Tally: Sendable { let value = Mutex(0) }
    private let tally: Tally
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let reader: Task<Void, Never>

    init() {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let tally = Tally()
        self.tally = tally
        reader = Task { for await _ in stream { tally.value.withLock { $0 += 1 } } }
    }

    var count: Int { tally.value.withLock { $0 } }
    func closed() async -> Bool { await reader.value; return true }
}

@Suite struct AppleLiveTranscriberTests {
    @Test func conversionFailureEndsTheStreamAndKeepsTheTimelineInStep() async throws {
        let t = DictationLiveTranscriber()
        let (results, _) = AsyncThrowingStream<RecognizedSegment, Error>.makeStream()
        let input = InputCounter()
        let stream = await t.begin(analyzer: nil, results: results, input: input.continuation,
                                   converter: FakeAnalyzerConverter(failOn: [2]))
        await t.feed(chunk(tone(0.5), at: 0))
        await t.feed(chunk(tone(0.5), at: 0.5))
        await t.feed(chunk(tone(0.5), at: 1))
        #expect(await collect(stream).isEmpty)
        #expect(await t.audioSeconds == 0.5)
        #expect(await input.closed())
        #expect(input.count == 1)
        await t.finish()
    }

    @Test func resultsFlowThroughTheAssemblerUntilFinish() async throws {
        let t = DictationLiveTranscriber()
        let (results, resultsContinuation) = AsyncThrowingStream<RecognizedSegment, Error>.makeStream()
        let input = InputCounter()
        let stream = await t.begin(analyzer: nil, results: results, input: input.continuation, converter: FakeAnalyzerConverter())
        let reader = Task { await collect(stream) }
        await t.feed(chunk(tone(1), at: 10))
        resultsContinuation.yield(RecognizedSegment(audioStart: 0.2, audioEnd: 0.8, text: "会議", isFinal: true))
        resultsContinuation.finish()
        await t.finish()
        #expect(await reader.value == [Utterance(start: TimelineTime(seconds: 10.2), end: TimelineTime(seconds: 10.8),
                                                 speaker: .unknown, text: "会議", isFinal: true)])
    }

    @Test func finishFlushesTheConverterOnceBeforeClosingTheInput() async throws {
        let t = DictationLiveTranscriber()
        let (results, resultsContinuation) = AsyncThrowingStream<RecognizedSegment, Error>.makeStream()
        let input = InputCounter()
        let converter = FakeAnalyzerConverter(flushFrames: 8)
        let stream = await t.begin(analyzer: nil, results: results, input: input.continuation, converter: converter)
        let reader = Task { await collect(stream) }
        await t.feed(chunk(tone(0.5), at: 0))
        resultsContinuation.finish()
        await t.finish()
        await t.finish()
        #expect(await input.closed())
        #expect(input.count == 2)
        #expect(converter.flushes == 1)
        #expect(await reader.value.isEmpty)
    }

    @Test func consumerStoppingCancelsTheResults() async throws {
        let t = DictationLiveTranscriber()
        let resultsEnded = Flag()
        let (results, resultsContinuation) = AsyncThrowingStream<RecognizedSegment, Error>.makeStream()
        resultsContinuation.onTermination = { _ in resultsEnded.value.withLock { $0 = true } }
        let input = InputCounter()
        let stream = await t.begin(analyzer: nil, results: results, input: input.continuation, converter: FakeAnalyzerConverter())
        let reader = Task { for await _ in stream {} }
        reader.cancel()
        try await waitUntil { resultsEnded.value.withLock { $0 } }
        #expect(await input.closed())
        await t.feed(chunk(tone(0.5), at: 0))
        #expect(await t.audioSeconds == 0)
    }
}
