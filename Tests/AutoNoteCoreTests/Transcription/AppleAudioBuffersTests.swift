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
}
