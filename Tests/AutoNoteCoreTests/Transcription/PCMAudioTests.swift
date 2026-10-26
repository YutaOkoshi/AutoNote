import AVFoundation
import AutoNoteCore
import AutoNoteTestSupport
import Testing

@Suite struct PCMAudioTests {
    @Test func chunksSplitAndKeepTimes() {
        let c = PCMAudio.chunks(Array(repeating: 1, count: 32_800), track: .system, chunkSeconds: 0.1,
                                start: TimelineTime(seconds: 5))
        #expect(c.count == 21)
        #expect(abs(c[1].start.seconds - 5.1) < 1e-9)
        #expect(c.last!.samples.count == 800)
        #expect(c.allSatisfy { $0.track == .system })
    }

    @Test func wavRoundTripAndResample() throws {
        let dir = try TemporaryDirectory.make()
        let wav = dir.appending(path: "a.wav")
        let samples = tone(1)
        try PCMAudio.writeWAV(samples, to: wav)
        #expect(try PCMAudio.readMono16k(wav) == samples)
        #expect(try WAVFile.readSamples(wav) == samples)

        let caf = dir.appending(path: "b.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: caf, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for ch in 0..<2 { for i in 0..<44_100 { buffer.floatChannelData![ch][i] = 0.3 * Float(sin(Double(i) * 0.05)) } }
            try file.write(from: buffer)
        }
        let out = try PCMAudio.readMono16k(caf)
        #expect(abs(out.count - 16_000) <= 160)
        #expect(out.contains { abs($0) > 5_000 })
    }

    @Test func floatsAreNormalised() {
        #expect(PCMAudio.floats([0, 16_384, -32_768]) == [0, 0.5, -1])
    }

    @Test func unreadableFileThrowsInvalidAudio() throws {
        let url = try TemporaryDirectory.make().appending(path: "x.wav")
        try Data("not audio".utf8).write(to: url)
        #expect(throws: TranscriptionError.self) { try PCMAudio.readMono16k(url) }
    }
}
