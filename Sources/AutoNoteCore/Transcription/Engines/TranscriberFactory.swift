import Foundation

/// Turns an `EngineChoice` into a transcriber. Whisper models are looked up in `ModelManager`
/// (not downloaded here: a missing one is `TranscriptionError.modelMissing`).
public struct TranscriberFactory: Sendable {
    /// Threads for live whisper decoding (batch uses `WhisperContext.batchThreads`).
    public static let liveWhisperThreads = 2

    private let models: ModelManager
    private let machine: MachineKind
    private let segmentation: SegmentationStrategy

    public init(models: ModelManager, machine: MachineKind, segmentation: SegmentationStrategy = .current) {
        self.models = models
        self.machine = machine
        self.segmentation = segmentation
    }

    public func makeLive(_ c: EngineChoice) async throws -> any LiveTranscriber {
        switch c.kind {
        case .dictation: return DictationLiveTranscriber(strategy: segmentation)
        case .speech: return SpeechLiveTranscriber(strategy: segmentation)
        case .whisper: return try Self.whisperLive(modelURL: try await modelURL(c), machine: machine)
        }
    }

    public func makeBatch(_ c: EngineChoice, gate: BatchGate) async throws -> any BatchTranscriber {
        switch c.kind {
        case .dictation, .speech:
            throw TranscriptionError.engineUnavailable("\(c.kind.rawValue) cannot run as a batch engine")
        case .whisper:
            return try Self.whisperBatch(modelURL: try await modelURL(c), machine: machine, gate: gate)
        }
    }

    /// Live whisper on a model file outside the manager (the dev CLI's `--model-path`).
    public static func whisperLive(modelURL: URL, machine: MachineKind) throws -> any LiveTranscriber {
        WhisperLiveTranscriber(core: try WhisperContext(modelURL: modelURL, machine: machine, threads: liveWhisperThreads))
    }

    /// Batch whisper on a model file outside the manager (the dev CLI's `--model-path`).
    public static func whisperBatch(modelURL: URL, machine: MachineKind, gate: BatchGate) throws -> any BatchTranscriber {
        WhisperBatchTranscriber(
            core: try WhisperContext(modelURL: modelURL, machine: machine, threads: WhisperContext.batchThreads), gate: gate)
    }

    private func modelURL(_ c: EngineChoice) async throws -> URL {
        let name = c.model ?? ""
        guard let url = await models.fileURL(for: name) else { throw TranscriptionError.modelMissing(name) }
        return url
    }
}
