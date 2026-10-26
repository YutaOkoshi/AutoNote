import Foundation

/// Finds utterance ends: speech of at least `minSpeech` followed by `minSilence` of quiet.
/// Frames are 20 ms; a frame is silent when its RMS (Int16 normalised to ±1) is below `threshold`.
public struct SilenceDetector: Sendable {
    private static let frameSamples = 320
    private static let frameSeconds = 0.02

    private let threshold: Double
    private let minSilenceFrames: Int
    private let minSpeechFrames: Int

    private var pending: [Int16] = []
    private var frameIndex = 0
    private var speechFrames = 0
    private var silenceRun = 0
    private var silenceStart = 0

    public init(threshold: Double = 0.01, minSilence: Double = 0.8, minSpeech: Double = 0.3) {
        self.threshold = threshold
        minSilenceFrames = max(1, Int((minSilence / Self.frameSeconds).rounded()))
        minSpeechFrames = max(1, Int((minSpeech / Self.frameSeconds).rounded()))
    }

    /// Feeds audio and returns the audio-second position (start of the silence) of each utterance end found.
    public mutating func process(_ samples: [Int16]) -> [Double] {
        pending.append(contentsOf: samples)
        var boundaries: [Double] = []
        var offset = 0
        while pending.count - offset >= Self.frameSamples {
            let isSpeech = isSpeechFrame(pending[offset..<(offset + Self.frameSamples)])
            offset += Self.frameSamples
            if isSpeech {
                speechFrames += 1
                silenceRun = 0
            } else {
                if silenceRun == 0 { silenceStart = frameIndex }
                silenceRun += 1
                if silenceRun == minSilenceFrames {
                    if speechFrames >= minSpeechFrames { boundaries.append(Double(silenceStart) * Self.frameSeconds) }
                    speechFrames = 0
                }
            }
            frameIndex += 1
        }
        pending.removeFirst(offset)
        return boundaries
    }

    /// Whether `samples` (whole 20 ms frames on the 0-based grid overlapping `start..<end` seconds) hold at
    /// least `minSpeech` of frames at or above the threshold. A trailing partial frame counts as a frame.
    public func hasSpeech(in samples: [Int16], from start: Double, to end: Double) -> Bool {
        let first = max(0, Int((start / Self.frameSeconds).rounded(.down)))
        let last = min(Int((end / Self.frameSeconds).rounded(.up)), (samples.count + Self.frameSamples - 1) / Self.frameSamples)
        guard first < last else { return false }
        var speech = 0
        for frame in first..<last {
            let lower = frame * Self.frameSamples
            if isSpeechFrame(samples[lower..<min(lower + Self.frameSamples, samples.count)]) {
                speech += 1
                if speech >= minSpeechFrames { return true }
            }
        }
        return false
    }

    /// RMS of the frame (Int16 normalised to ±1) at or above the threshold.
    private func isSpeechFrame(_ frame: ArraySlice<Int16>) -> Bool {
        var sum = 0.0
        for sample in frame {
            let v = Double(sample) / 32_768
            sum += v * v
        }
        return (sum / Double(frame.count)).squareRoot() >= threshold
    }
}
