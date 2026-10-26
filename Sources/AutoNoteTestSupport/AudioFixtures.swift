import Foundation
import AutoNoteCore

public enum AudioFixtures {
    public static func tone(start: Double, seconds: Double, value: Int16 = 1000, track: Track = .mic) -> AudioChunk {
        chunk(start: start, seconds: seconds, value: value, track: track)
    }

    public static func zeros(start: Double, seconds: Double, track: Track = .mic) -> AudioChunk {
        chunk(start: start, seconds: seconds, value: 0, track: track)
    }

    /// Interleaved float sine, `channels` copies of the same signal per frame.
    public static func sine(frequency: Double, amplitude: Float, seconds: Double, sampleRate: Double, channels: Int) -> [Float] {
        let frames = Int((seconds * sampleRate).rounded())
        var out = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
            for c in 0..<channels { out[i * channels + c] = v }
        }
        return out
    }

    private static func chunk(start: Double, seconds: Double, value: Int16, track: Track) -> AudioChunk {
        let n = Int((seconds * AudioChunk.sampleRate).rounded())
        return AudioChunk(track: track, samples: [Int16](repeating: value, count: n),
                          start: TimelineTime(seconds: start), hostTime: 0)
    }
}
