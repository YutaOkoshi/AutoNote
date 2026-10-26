@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import Speech

public typealias DictationLiveTranscriber = AppleLiveTranscriber<DictationAdapter>
public typealias SpeechLiveTranscriber = AppleLiveTranscriber<SpeechAdapter>

/// Realtime transcription with Apple's `SpeechAnalyzer` (the flow measured in plan 00's AppleSpeechProbe).
/// `start` sets the analyzer up and returns at once; a results task yields utterances through the stream.
/// An analyzer error after `start` ends the stream (logged to stderr once).
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
    private var analysisFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<Utterance>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizing: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var started = false
    private var accepting = false
    private var loggedFailure = false

    public init(strategy: SegmentationStrategy = .current) {
        requestedStrategy = strategy
    }

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
        let inputStream: AsyncStream<AnalyzerInput>
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
            if format != AppleAudioBuffers.format {
                guard let c = AVAudioConverter(from: AppleAudioBuffers.format, to: format) else {
                    throw TranscriptionError.engineUnavailable("\(Adapter.engineKind): cannot convert audio to \(format)")
                }
                converter = c
            }
            analysisFormat = format
            try await analyzer.prepareToAnalyze(in: format)
            (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputStream)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engineUnavailable(String(describing: error))
        }
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.analyzer = analyzer
        self.continuation = continuation
        input = inputContinuation
        accepting = true
        resultsTask = Task { await consume(results) }
        return stream
    }

    public func feed(_ chunk: AudioChunk) async {
        guard accepting, let input, !chunk.samples.isEmpty else { return }
        mapper.append(chunk)
        guard let buffer = convert(AppleAudioBuffers.pcmBuffer(chunk)) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
        if strategy == .silenceFinalize {
            for boundary in detector.process(chunk.samples) { scheduleFinalize(through: boundary) }
        }
    }

    /// Closes the input, lets the analyzer finalize everything fed, then ends the stream.
    /// Later (or concurrent) calls wait for the same ending.
    public func finish() async {
        if accepting {
            accepting = false
            input?.finish()
            input = nil
            let analyzer = analyzer
            finishing = Task {
                await finalizing?.value
                do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch {
                    logFailure("finalize failed", error)
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

    private func consume(_ results: AsyncThrowingStream<RecognizedSegment, Error>) async {
        do {
            for try await segment in results { continuation?.yield(assembler.consume(segment, mapper: mapper)) }
        } catch {
            logFailure("recognition failed", error)
            accepting = false
            input?.finish()
            input = nil
            await analyzer?.cancelAndFinishNow()
        }
        endStream()
    }

    private func endStream() {
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
                logFailure("finalize at \(boundary) s failed", error)
            }
        }
    }

    /// Converts to the analyzer's format with the one reused converter (nil converter: formats already match).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let format = analysisFormat else { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / AppleAudioBuffers.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false                    // the input block runs synchronously inside convert
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            logFailure("audio conversion failed", error ?? NSError(domain: "AVAudioConverter", code: -1))
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    private func logFailure(_ what: String, _ error: Error) {
        guard !loggedFailure else { return }
        loggedFailure = true
        FileHandle.standardError.write(Data("\(Adapter.engineKind) live: \(what): \(error)\n".utf8))
    }
}
