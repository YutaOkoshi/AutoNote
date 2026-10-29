@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import Speech

public typealias DictationLiveTranscriber = AppleLiveTranscriber<DictationAdapter>
public typealias SpeechLiveTranscriber = AppleLiveTranscriber<SpeechAdapter>

/// Realtime transcription with Apple's `SpeechAnalyzer` (the flow measured in the plan 00 AppleSpeechProbe spike; see docs/superpowers/research/2026-10-24-spike-results.md).
/// `start` sets the analyzer up and returns at once; a results task yields utterances through the stream.
/// A recognition or audio-conversion error after `start` tears the session down and ends the stream (always
/// logged to stderr); a consumer that stops reading the stream tears it down too.
public actor AppleLiveTranscriber<Adapter: AppleSpeechModuleAdapter>: LiveTranscriber {
    /// Upper bound on contextual strings handed to the analyzer (plan 04 Task 7).
    static var maxHints: Int { 100 }

    private let requestedStrategy: SegmentationStrategy
    private var strategy: SegmentationStrategy = .engineDefault
    private var mapper = TimelineMapper()
    private var assembler = UtteranceAssembler()
    private var detector = SilenceDetector()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: (any AnalyzerAudioConverting)?
    private var continuation: AsyncStream<Utterance>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizing: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var started = false
    private var accepting = false
    private var ended = false
    private var loggedSites: Set<String> = []

    public init(strategy: SegmentationStrategy = .current) {
        requestedStrategy = strategy
    }

    /// Seconds of audio the analyzer has been given (for tests).
    var audioSeconds: Double { mapper.audioSeconds }

    public func start(language: Language, hints: [String]) async throws -> AsyncStream<Utterance> {
        guard !started else { throw TranscriptionError.engineUnavailable("already started") }
        started = true
        let wanted = LocaleMapping.locale(for: language)
        guard let locale = await Adapter.supportedLocales().first(where: { LocaleMapping.contains([$0], wanted) }) else {
            throw TranscriptionError.localeUnsupported(language)
        }
        strategy = Adapter.supports(requestedStrategy) ? requestedStrategy : .silenceFinalize
        let (module, results) = Adapter.makeModule(locale: locale, strategy: strategy)
        let analyzer: SpeechAnalyzer
        let converter: any AnalyzerAudioConverting
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            analyzer = SpeechAnalyzer(modules: [module])
            if !hints.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(hints.prefix(Self.maxHints))
                try await analyzer.setContext(context)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw TranscriptionError.engineUnavailable("\(Adapter.engineKind): no compatible audio format")
            }
            if format == AppleAudioBuffers.format {
                converter = PassthroughAudioConverter()
            } else {
                guard let c = AnalyzerAudioConverter(to: format) else {
                    throw TranscriptionError.engineUnavailable("\(Adapter.engineKind): cannot convert audio to \(format)")
                }
                converter = c
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation
            try await analyzer.start(inputSequence: inputStream)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
        return begin(analyzer: analyzer, results: results, input: inputContinuation, converter: converter)
    }

    /// Runs a session on an analyzer that is already started (tests pass `analyzer: nil` and fakes).
    func begin(analyzer: SpeechAnalyzer?, results: AsyncThrowingStream<RecognizedSegment, Error>,
               input: AsyncStream<AnalyzerInput>.Continuation, converter: sending any AnalyzerAudioConverting)
        -> AsyncStream<Utterance> {
        started = true
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.consumerStopped() }
        }
        self.analyzer = analyzer
        self.input = input
        self.converter = converter
        self.continuation = continuation
        accepting = true
        resultsTask = Task { await readResults(results) }
        return stream
    }

    public func feed(_ chunk: AudioChunk) async {
        guard accepting, let input, let converter, !chunk.samples.isEmpty else { return }
        let buffer: AVAudioPCMBuffer?
        do { buffer = try converter.convert(AppleAudioBuffers.pcmBuffer(chunk)) } catch {
            log("audio conversion failed; stopping", error, always: true)
            tearDown()
            return
        }
        mapper.append(chunk)                                      // only audio the analyzer actually receives
        if let buffer { input.yield(AnalyzerInput(buffer: buffer)) }
        if strategy == .silenceFinalize {
            for boundary in detector.process(chunk.samples) { scheduleFinalize(through: boundary) }
        }
    }

    /// Flushes the converter, closes the input, lets the analyzer finalize everything fed, then ends the stream.
    /// Later (or concurrent) calls wait for the same ending.
    public func finish() async {
        if accepting {
            accepting = false
            do {
                if let tail = try converter?.flush() { input?.yield(AnalyzerInput(buffer: tail)) }
            } catch {
                log("audio conversion flush failed", error)
            }
            input?.finish()
            input = nil
            let analyzer = analyzer
            finishing = Task {
                await finalizing?.value
                do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch {
                    log("finalize at end of input failed", error)
                    await analyzer?.cancelAndFinishNow()
                }
                await resultsTask?.value
                endStream()
            }
        } else if finishing == nil {
            finishing = Task { await resultsTask?.value; endStream() }
        }
        await finishing?.value
    }

    private func readResults(_ results: AsyncThrowingStream<RecognizedSegment, Error>) async {
        do {
            for try await segment in results { continuation?.yield(assembler.consume(segment, mapper: mapper)) }
        } catch {
            log("recognition failed; stopping", error, always: true)
            tearDown()
        }
        endStream()
    }

    /// Stops the session at once: no more feeds, input closed, results cancelled, analyzer cancelled, stream ended.
    private func tearDown() {
        accepting = false
        input?.finish()
        input = nil
        resultsTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        endStream()
    }

    private func consumerStopped() {
        guard !ended else { return }
        tearDown()
    }

    private func endStream() {
        ended = true
        continuation?.finish()
        continuation = nil
    }

    /// Finalizes in order, without holding up `feed`.
    private func scheduleFinalize(through boundary: Double) {
        guard let analyzer else { return }
        let previous = finalizing
        finalizing = Task {
            await previous?.value
            do { try await analyzer.finalize(through: CMTime(seconds: boundary, preferredTimescale: 16_000)) } catch {
                log("finalize at a silence boundary failed", error)
            }
        }
    }

    /// Logs each distinct non-fatal failure once; `always` is for the error that ends the stream.
    private func log(_ site: String, _ error: Error, always: Bool = false) {
        guard always || loggedSites.insert(site).inserted else { return }
        FileHandle.standardError.write(Data("\(Adapter.engineKind) live: \(site): \(error)\n".utf8))
    }
}
