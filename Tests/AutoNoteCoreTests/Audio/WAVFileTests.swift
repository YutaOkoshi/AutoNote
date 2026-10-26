import Testing
import Foundation
import AVFoundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct WAVFileTests {
    @Test func repairsZeroSizedHeader() throws {
        let dir = try TemporaryDirectory.make()
        let url = dir.appending(path: "a.wav")
        var data = WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 0)
        data.append(Data(repeating: 1, count: 32_000))
        try data.write(to: url)
        let info = try #require(try WAVFile.repairHeader(url))
        #expect(info.durationSeconds == 1.0 && info.dataBytes == 32_000)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 16_000)
    }

    @Test func repairReturnsNilForTruncatedFile() throws {
        let dir = try TemporaryDirectory.make()
        let url = dir.appending(path: "b.wav")
        try Data(repeating: 0, count: 20).write(to: url)
        #expect(try WAVFile.repairHeader(url) == nil)
    }

    @Test func readSamplesRoundTrips() throws {
        let dir = try TemporaryDirectory.make()
        let url = dir.appending(path: "c.wav")
        var data = WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 4)
        data.append(contentsOf: [0x01, 0x00, 0xFF, 0xFF])
        try data.write(to: url)
        #expect(try WAVFile.readSamples(url) == [1, -1])
    }
}
