import Foundation
import AutoNoteCore

public struct FakeError: Error, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

public actor CallLog {
    public private(set) var entries: [String] = []
    public init() {}
    public func append(_ entry: String) { entries.append(entry) }
}

/// `start` hands the scripted chunks to `onBuffer`; `emit` delivers more while started.
public actor FakeAudioSource: AudioSource {
    public nonisolated let track: Track
    private let chunks: [AudioChunk]
    private let startError: (any Error)?
    private var onBuffer: (@Sendable (AudioChunk) -> Void)?
    public private(set) var isStarted = false
    public private(set) var stopCount = 0

    public init(track: Track, chunks: [AudioChunk] = [], startError: (any Error)? = nil) {
        self.track = track; self.chunks = chunks; self.startError = startError
    }

    public func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws {
        if let startError { throw startError }
        self.onBuffer = onBuffer
        isStarted = true
        for chunk in chunks { onBuffer(chunk) }
    }

    /// Calls the `onBuffer` given to `start` synchronously; ignored when not started.
    public func emit(_ chunk: AudioChunk) { onBuffer?(chunk) }

    public func stop() async {
        stopCount += 1
        isStarted = false
        onBuffer = nil
    }
}

/// Streams its script from `start` (or throws `startError` when set); `finish` closes the stream.
public actor FakeLiveTranscriber: LiveTranscriber {
    private let script: [Utterance]
    private let startError: FakeError?
    private var continuation: AsyncStream<Utterance>.Continuation?
    public private(set) var fedChunks: [AudioChunk] = []
    public private(set) var startedWith: (Language, [String])?

    public init(script: [Utterance], startError: FakeError? = nil) {
        self.script = script; self.startError = startError
    }

    public func start(language: Language, hints: [String]) async throws -> AsyncStream<Utterance> {
        startedWith = (language, hints)
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<Utterance>.makeStream()
        self.continuation = continuation
        for utterance in script { continuation.yield(utterance) }
        return stream
    }

    public func feed(_ chunk: AudioChunk) async { fedChunks.append(chunk) }

    public func finish() async {
        continuation?.finish()
        continuation = nil
    }
}

/// Results are keyed by the file's `lastPathComponent`.
public actor FakeBatchTranscriber: BatchTranscriber {
    private let results: [String: [Utterance]]
    private let failure: FakeError?
    public private(set) var calls: [URL] = []

    public init(results: [String: [Utterance]], failure: FakeError? = nil) {
        self.results = results; self.failure = failure
    }

    public func transcribe(file: URL, language: Language, hints: [String], progress: @Sendable @escaping (Double) -> Void) async throws -> [Utterance] {
        calls.append(file)
        progress(0)
        if let failure { throw failure }
        guard let utterances = results[file.lastPathComponent] else {
            throw FakeError(message: "no scripted result for \(file.lastPathComponent)")
        }
        progress(1)
        return utterances
    }
}

public actor FakeSummarizer: Summarizer {
    private let result: Result<MinutesOutput, FakeError>
    public private(set) var inputs: [SummaryInput] = []

    public init(result: Result<MinutesOutput, FakeError>) { self.result = result }

    public func summarize(_ input: SummaryInput) async throws -> MinutesOutput {
        inputs.append(input)
        return try result.get()
    }
}

public struct FakeQueueStage: QueueStage {
    public let name: String
    private let log: CallLog
    private let failure: FakeError?

    public init(name: String, log: CallLog, failure: FakeError?) {
        self.name = name; self.log = log; self.failure = failure
    }

    public func run(_ job: inout Job, context: StageContext) async throws {
        await log.append(name)
        if let failure { throw failure }
    }
}
