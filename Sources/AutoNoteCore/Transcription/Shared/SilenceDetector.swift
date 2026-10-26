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
            var sum = 0.0
            for i in offset..<(offset + Self.frameSamples) {
                let v = Double(pending[i]) / 32_768
                sum += v * v
            }
            let rms = (sum / Double(Self.frameSamples)).squareRoot()
            offset += Self.frameSamples
            if rms >= threshold {
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
}
