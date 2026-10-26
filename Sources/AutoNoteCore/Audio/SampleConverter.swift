import Foundation
@preconcurrency import AVFoundation

/// Single-use input supplier for one AVAudioConverter pull; the block runs synchronously.
private final class InputFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let isFlush: Bool
    init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer; isFlush = buffer == nil }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let b = buffer { buffer = nil; status.pointee = .haveData; return b }
        status.pointee = isFlush ? .endOfStream : .noDataNow
        return nil
    }
}

public enum SampleConverterError: Error, Equatable {
    case unsupportedFormat(sampleRate: Double, channels: Int)
}

public enum AudioLevel {
    /// Peak level in dBFS (20·log10(max|x| / 32768)); `-infinity` when every sample is zero.
    public static func peakDBFS<C: Collection>(_ samples: C) -> Double where C.Element == Int16 {
        var peak = 0
        for s in samples { peak = max(peak, abs(Int(s))) }
        guard peak > 0 else { return -.infinity }
        return 20 * log10(Double(peak) / 32768)
    }
}

/// Converts interleaved Float frames at any rate / channel count to 16 kHz mono Int16.
/// Stateful (resampler history), not Sendable: use from a single consumer task only.
public struct SampleConverter {
    private static let outputRate = 16_000.0

    private let inputChannels: Int
    private let inputRate: Double
    private let converter: AVAudioConverter?   // nil when input is already 16 kHz
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var mono: [Float] = []

    public init(inputSampleRate: Double, inputChannels: Int) throws {
        guard inputChannels > 0, inputSampleRate > 0, inputSampleRate.isFinite,
              let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false)
        else { throw SampleConverterError.unsupportedFormat(sampleRate: inputSampleRate, channels: inputChannels) }
        self.inputChannels = inputChannels
        self.inputRate = inputSampleRate
        self.inputFormat = inFmt
        self.outputFormat = outFmt
        if inputSampleRate == Self.outputRate {
            converter = nil
        } else {
            guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
                throw SampleConverterError.unsupportedFormat(sampleRate: inputSampleRate, channels: inputChannels)
            }
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = conv
        }
    }

    public mutating func convert(_ interleaved: [Float]) -> [Int16] {
        let frames = interleaved.count / inputChannels
        guard frames > 0 else { return [] }
        mono.removeAll(keepingCapacity: true)
        if inputChannels == 1 {
            mono.append(contentsOf: interleaved.prefix(frames))
        } else {
            let scale = 1 / Float(inputChannels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<inputChannels { sum += interleaved[f * inputChannels + c] }
                mono.append(sum * scale)
            }
        }
        guard let converter else { return Self.toInt16(mono) }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: frames)
        }
        return run(converter, input: inBuf, expectedFrames: frames)
    }

    /// Drains the resampler's tail, then resets it so the converter can be reused.
    public mutating func flush() -> [Int16] {
        guard let converter else { return [] }
        let out = run(converter, input: nil, expectedFrames: 0)
        converter.reset()
        return out
    }

    public mutating func reset() {
        converter?.reset()
        mono.removeAll(keepingCapacity: true)
    }

    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, expectedFrames: Int) -> [Int16] {
        let capacity = AVAudioFrameCount(Double(expectedFrames) * Self.outputRate / inputRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        let feed = InputFeed(input)
        var result: [Int16] = []
        while true {
            outBuf.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, inStatus in
                feed.next(inStatus)
            }
            if status == .error { break }
            let n = Int(outBuf.frameLength)
            if n > 0 {
                result += Self.toInt16(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
            }
            // Output not filled => converter has consumed everything it can for now.
            if n < Int(capacity) || status != .haveData { break }
        }
        return result
    }

    private static func toInt16<S: Sequence>(_ x: S) -> [Int16] where S.Element == Float {
        x.map { Int16((max(-1, min(1, $0)) * 32767).rounded()) }
    }
}
