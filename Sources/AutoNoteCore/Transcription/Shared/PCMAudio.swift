@preconcurrency import AVFoundation
import Foundation

public enum PCMAudio {
    public static let sampleRate = 16_000.0

    /// Reads any `AVAudioFile`-readable file as 16 kHz mono Int16 (16 kHz mono WAVs are read directly).
    public static func readMono16k(_ url: URL) throws -> [Int16] {
        if let info = try? WAVFile.info(url), info.sampleRate == 16_000, info.channels == 1, info.bitsPerSample == 16 {
            return try WAVFile.readSamples(url)
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw TranscriptionError.invalidAudio("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw TranscriptionError.invalidAudio("\(url.lastPathComponent): unsupported format")
        }
        let inputCapacity: AVAudioFrameCount = 32_768
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * sampleRate / file.processingFormat.sampleRate) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inputCapacity) else {
            throw TranscriptionError.invalidAudio("\(url.lastPathComponent): cannot allocate buffers")
        }
        var samples: [Int16] = []
        let feed = ConverterFeed(file: file, input: input, capacity: inputCapacity)
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in feed.next(inputStatus) }
            if let failure = feed.failure { throw TranscriptionError.invalidAudio("\(url.lastPathComponent): \(failure.localizedDescription)") }
            if status == .error {
                throw TranscriptionError.invalidAudio("\(url.lastPathComponent): \(error?.localizedDescription ?? "conversion failed")")
            }
            if output.frameLength > 0, let data = output.int16ChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
        }
        return samples
    }

    /// Writes a 16 kHz mono 16-bit WAV.
    public static func writeWAV(_ samples: [Int16], to url: URL) throws {
        var data = WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: samples.count * 2)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    public static func floats(_ s: [Int16]) -> [Float] { s.map { Float($0) / 32_768 } }

    public static func chunks(_ s: [Int16], track: Track, chunkSeconds: Double, start: TimelineTime) -> [AudioChunk] {
        let size = max(1, Int((chunkSeconds * sampleRate).rounded()))
        return stride(from: 0, to: s.count, by: size).map { offset in
            AudioChunk(track: track, samples: Array(s[offset..<min(offset + size, s.count)]),
                       start: TimelineTime(seconds: start.seconds + Double(offset) / sampleRate), hostTime: 0)
        }
    }
}

/// Feeds file reads to `AVAudioConverter`; only touched from the converter's synchronous callback.
private final class ConverterFeed: @unchecked Sendable {
    let file: AVAudioFile
    let input: AVAudioPCMBuffer
    let capacity: AVAudioFrameCount
    var finished = false
    var failure: Error?

    init(file: AVAudioFile, input: AVAudioPCMBuffer, capacity: AVAudioFrameCount) {
        self.file = file; self.input = input; self.capacity = capacity
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if finished || file.framePosition >= file.length { finished = true; status.pointee = .endOfStream; return nil }
        do {
            input.frameLength = 0
            try file.read(into: input, frameCount: capacity)
        } catch {
            failure = error; finished = true; status.pointee = .endOfStream; return nil
        }
        if input.frameLength == 0 { finished = true; status.pointee = .endOfStream; return nil }
        status.pointee = .haveData
        return input
    }
}
