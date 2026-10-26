@preconcurrency import AVFoundation
import Foundation

enum AppleAudioBuffers {
    /// 16 kHz mono interleaved Int16, the format of every `AudioChunk`.
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: true)!

    /// Copies a chunk's samples into an `AVAudioPCMBuffer` (an empty chunk gives an empty buffer).
    static func pcmBuffer(_ chunk: AudioChunk) -> AVAudioPCMBuffer {
        let count = chunk.samples.count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, count)))!
        buffer.frameLength = AVAudioFrameCount(count)
        if count > 0 {
            chunk.samples.withUnsafeBufferPointer { src in
                buffer.int16ChannelData![0].update(from: src.baseAddress!, count: count)
            }
        }
        return buffer
    }
}
