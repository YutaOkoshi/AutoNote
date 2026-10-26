import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Synchronization

/// Shared audio/stream helpers for the transcription tests (and the one module-wide `waitUntil`).
func tone(_ sec: Double) -> [Int16] { (0..<Int(sec * 16_000)).map { Int16(8000 * sin(Double($0) * 0.1)) } }
func silence(_ sec: Double) -> [Int16] { Array(repeating: 0, count: Int(sec * 16_000)) }
func chunk(_ s: [Int16], at t: Double, track: Track = .mic) -> AudioChunk {
    AudioChunk(track: track, samples: s, start: TimelineTime(seconds: t), hostTime: 0)
}

/// An unconfirmed live utterance.
func partial(_ seconds: Double, _ text: String) -> Utterance {
    Utterance(start: TimelineTime(seconds: seconds), end: nil, speaker: .unknown, text: text, isFinal: false)
}

/// A 16 kHz mono silent WAV of the given length in a fresh temporary folder.
func wavFile(seconds: Double) throws -> URL {
    let url = try TemporaryDirectory.make().appending(path: "silence.wav")
    try PCMAudio.writeWAV(silence(seconds), to: url)
    return url
}

final class ProgressBox: @unchecked Sendable {
    private let storage = Mutex<[Double]>([])
    func append(_ value: Double) { storage.withLock { $0.append(value) } }
    var values: [Double] { storage.withLock { $0 } }
}

/// Drains a stream into an array.
func collect<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
    var out: [T] = []
    for await element in stream { out.append(element) }
    return out
}

struct WaitTimedOut: Error {}

/// Polls `condition` every 10 ms for at most about 5 s.
func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
