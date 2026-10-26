import Foundation

/// 16 kHz mono Int16 audio with its position on the meeting timeline.
public struct AudioChunk: Sendable, Equatable {
    public static let sampleRate = 16_000.0

    public var track: Track
    public var samples: [Int16]
    /// Start on the meeting timeline.
    public var start: TimelineTime
    public var hostTime: UInt64

    public init(track: Track, samples: [Int16], start: TimelineTime, hostTime: UInt64) {
        self.track = track; self.samples = samples; self.start = start; self.hostTime = hostTime
    }

    public var duration: Double { Double(samples.count) / Self.sampleRate }
}

public protocol AudioSource: Sendable {
    var track: Track { get }
    func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws
    func stop() async
}
