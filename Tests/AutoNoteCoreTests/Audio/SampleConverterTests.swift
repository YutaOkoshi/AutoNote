import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

private func zeroCrossings(_ x: [Int16]) -> Int {
    var n = 0
    for i in 1..<max(x.count, 1) where (x[i - 1] < 0) != (x[i] < 0) { n += 1 }
    return n
}

@Suite struct SampleConverterTests {
    @Test func stereo48kTo16kMono() throws {
        var c = try SampleConverter(inputSampleRate: 48_000, inputChannels: 2)
        let src = AudioFixtures.sine(frequency: 1000, amplitude: 0.5, seconds: 1, sampleRate: 48_000, channels: 2)
        var out: [Int16] = []
        for i in stride(from: 0, to: src.count, by: 960) { out += c.convert(Array(src[i..<min(i + 960, src.count)])) }
        out += c.flush()
        #expect(abs(out.count - 16_000) <= 32)
        #expect(abs(AudioLevel.peakDBFS(out) - (-6.02)) < 0.5)
        #expect(abs(zeroCrossings(out) - 2000) <= 20)
    }

    @Test func downmixAveragesChannels() throws {
        var c = try SampleConverter(inputSampleRate: 48_000, inputChannels: 2)
        let mono = AudioFixtures.sine(frequency: 1000, amplitude: 0.5, seconds: 1, sampleRate: 48_000, channels: 1)
        var src = [Float](repeating: 0, count: mono.count * 2)
        for (i, v) in mono.enumerated() { src[2 * i] = v; src[2 * i + 1] = -v }
        let out = c.convert(src) + c.flush()
        #expect(out.count > 15_000)
        #expect(AudioLevel.peakDBFS(out) < -60)
    }

    @Test func clipsInsteadOfOverflowing() throws {
        var c = try SampleConverter(inputSampleRate: 16_000, inputChannels: 1)
        let src = AudioFixtures.sine(frequency: 300, amplitude: 1.5, seconds: 1, sampleRate: 16_000, channels: 1)
        let out = c.convert(src) + c.flush()
        #expect(out.max() == 32_767)
        #expect(out.min() == -32_767 || out.min() == -32_768)
        // no wrap-around: a 300 Hz sine crosses zero ~600 times in 1 s
        #expect(abs(zeroCrossings(out) - 600) <= 4)
    }

    @Test(arguments: [8_000.0, 16_000, 24_000, 44_100])
    func convertsBluetoothRates(rate: Double) throws {
        var c = try SampleConverter(inputSampleRate: rate, inputChannels: 1)
        let out = c.convert(AudioFixtures.sine(frequency: 300, amplitude: 0.5, seconds: 2, sampleRate: rate, channels: 1)) + c.flush()
        #expect(abs(out.count - 32_000) <= 64)
    }

    @Test func resetClearsState() throws {
        var c = try SampleConverter(inputSampleRate: 48_000, inputChannels: 1)
        let src = AudioFixtures.sine(frequency: 1000, amplitude: 0.5, seconds: 0.5, sampleRate: 48_000, channels: 1)
        let first = c.convert(src) + c.flush()
        c.reset()
        let second = c.convert(src) + c.flush()
        #expect(first.count == second.count)
    }

    @Test func silenceIsMinusInfinity() { #expect(AudioLevel.peakDBFS([Int16](repeating: 0, count: 10)) == -.infinity) }
    @Test func rejectsZeroChannels() { #expect(throws: SampleConverterError.self) { try SampleConverter(inputSampleRate: 48_000, inputChannels: 0) } }
}
