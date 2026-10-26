import Foundation

public protocol LiveTranscriber: Sendable {
    func start(language: Language, hints: [String]) async throws -> AsyncStream<Utterance>
    func feed(_ chunk: AudioChunk) async
    func finish() async
}

public protocol BatchTranscriber: Sendable {
    func transcribe(file: URL, language: Language, hints: [String], progress: @Sendable @escaping (Double) -> Void) async throws -> [Utterance]
}
