import AVFoundation
import Testing
@testable import AutoNoteCore

@Suite struct AppleAudioBuffersTests {
    @Test func pcmBufferKeepsSamples() {
        let s = (0..<1600).map { Int16($0) }; let b = AppleAudioBuffers.pcmBuffer(chunk(s, at: 0))
        #expect(b.frameLength == 1600); #expect(b.format.sampleRate == 16_000); #expect(b.format.channelCount == 1); #expect(b.int16ChannelData![0][5] == 5)
    }

    @Test func pcmBufferIsInt16() {
        let b = AppleAudioBuffers.pcmBuffer(chunk([1, -1, 32_767], at: 0))
        #expect(b.format.commonFormat == .pcmFormatInt16)
        #expect(Array(UnsafeBufferPointer(start: b.int16ChannelData![0], count: Int(b.frameLength))) == [1, -1, 32_767])
    }

    @Test func emptyChunkGivesEmptyBuffer() {
        #expect(AppleAudioBuffers.pcmBuffer(chunk([], at: 0)).frameLength == 0)
    }

    @Test func analyzerConverterResamplesAndFlushesTheTail() throws {
        let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let c = try #require(AnalyzerAudioConverter(to: target))
        var frames = 0
        for _ in 0..<10 { frames += Int(try c.convert(AppleAudioBuffers.pcmBuffer(chunk(tone(0.1), at: 0)))?.frameLength ?? 0) }
        frames += Int(try c.flush()?.frameLength ?? 0)
        #expect(abs(frames - 48_000) <= 48)
    }
}
