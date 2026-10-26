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

/// Turns `AppleAudioBuffers.format` buffers into the analyzer's input format.
/// `convert` returns nil when it succeeded but has no frames ready yet (they come out with later input or `flush`).
protocol AnalyzerAudioConverting: AnyObject {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer?
    /// Drains the frames still held at end of input; call once, last.
    func flush() throws -> AVAudioPCMBuffer?
}

/// The analyzer already takes `AppleAudioBuffers.format`.
final class PassthroughAudioConverter: AnalyzerAudioConverting {
    init() {}
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? { buffer }
    func flush() throws -> AVAudioPCMBuffer? { nil }
}

/// One reused `AVAudioConverter`, so resampler state carries across buffers.
final class AnalyzerAudioConverter: AnalyzerAudioConverting {
    struct Failed: Error, CustomStringConvertible { let description: String }

    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: AppleAudioBuffers.format, to: target) else { return nil }
        self.converter = converter
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? { try run(buffer, frames: buffer.frameLength) }

    func flush() throws -> AVAudioPCMBuffer? { try run(nil, frames: 0) }

    /// Feeds `input` once (then reports no data), or reports end of stream when `input` is nil.
    private func run(_ input: AVAudioPCMBuffer?, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / AppleAudioBuffers.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failed(description: "cannot allocate a \(capacity)-frame buffer")
        }
        nonisolated(unsafe) var pending = input                 // the input block runs synchronously inside convert
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            guard input != nil else { inputStatus.pointee = .endOfStream; return nil }
            guard let next = pending else { inputStatus.pointee = .noDataNow; return nil }
            pending = nil
            inputStatus.pointee = .haveData
            return next
        }
        if status == .error { throw Failed(description: error.map { "\($0)" } ?? "AVAudioConverter failed") }
        return out.frameLength > 0 ? out : nil
    }
}
