@preconcurrency import AVFoundation
import AutoNoteCore
import Foundation
import Synchronization

/// Development-only microphone capture for `dev transcribe --mic`: taps the default input with `AVAudioEngine`
/// and converts it to 16 kHz mono Int16 `AudioChunk`s (track `.mic`, `start` = seconds captured so far).
/// Independent of the app's recorder (`RecordingSession`) on purpose. The first run may trigger the microphone permission prompt.
/// The tap block is created here (not in a `@MainActor` context) because it runs on the audio thread.
final class DevMicCapture: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { var description: String }

    private let engine = AVAudioEngine()
    private let inputFormat: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter
    private let sampleCount = Mutex(0)

    init() throws {
        inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw Failure(description: "no input device (sample rate 0)") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: PCMAudio.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw Failure(description: "cannot convert \(inputFormat) to 16 kHz mono Int16")
        }
        self.target = target
        self.converter = converter
    }

    /// Seconds of audio delivered so far.
    var capturedSeconds: Double { Double(sampleCount.withLock { $0 }) / PCMAudio.sampleRate }

    func start(_ sink: @escaping @Sendable (AudioChunk) -> Void) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, _ in
            if let chunk = convert(buffer) { sink(chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Runs on the audio thread, one buffer at a time.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AudioChunk? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false                    // the input block runs synchronously inside convert
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let data = out.int16ChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        let offset = sampleCount.withLock { count in
            defer { count += samples.count }
            return count
        }
        return AudioChunk(track: .mic, samples: samples,
                          start: TimelineTime(seconds: Double(offset) / PCMAudio.sampleRate), hostTime: 0)
    }
}
