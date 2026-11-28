import Foundation

public protocol LiveTranscriber: Sendable {
    func start(language: Language, hints: [String]) async throws -> AsyncStream<Utterance>
    func feed(_ chunk: AudioChunk) async
    /// No more audio will be fed. Returns without waiting for results; `finish()` still has to be called.
    /// For what an engine wants to do at the moment of the stop, before another track is drained (default: nothing).
    func inputEnded() async
    func finish() async
}

extension LiveTranscriber {
    public func inputEnded() async {}
}

public protocol BatchTranscriber: Sendable {
    func transcribe(file: URL, language: Language, hints: [String], progress: @Sendable @escaping (Double) -> Void) async throws -> [Utterance]
}
