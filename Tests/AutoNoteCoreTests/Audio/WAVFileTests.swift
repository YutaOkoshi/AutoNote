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

    private func ramp(_ n: Int, dataBytes: Int? = nil) throws -> URL {
        let url = try TemporaryDirectory.make().appending(path: "r.wav")
        var data = WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: dataBytes ?? n * 2)
        (0..<n).map { Int16($0) }.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
        return url
    }

    @Test func sampleCountReadsTheHeader() throws { #expect(try WAVFile.sampleCount(try ramp(1000)) == 1000) }
    @Test func sampleCountUsesFileLengthWhenHeaderSizeIsZero() throws { #expect(try WAVFile.sampleCount(try ramp(1000, dataBytes: 0)) == 1000) }
    @Test func sampleCountClampsToFileLength() throws { #expect(try WAVFile.sampleCount(try ramp(1000, dataBytes: 64_000)) == 1000) }

    @Test func sampleCountDropsAnOddTrailingByte() throws {
        let url = try TemporaryDirectory.make().appending(path: "odd.wav")
        var data = WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: 0)
        data.append(Data(repeating: 1, count: 5))
        try data.write(to: url)
        #expect(try WAVFile.sampleCount(url) == 2)
    }

    @Test func sampleCountRejectsNonWAV() throws {
        let url = try TemporaryDirectory.make().appending(path: "x.wav")
        try Data("not a wav".utf8 + Array(repeating: 0, count: 11)).write(to: url)
        #expect(throws: WAVFileError.invalidHeader) { try WAVFile.sampleCount(url) }
    }

    @Test func rangedReadMatchesSlice() throws {
        let url = try ramp(1000)
        #expect(try WAVFile.readSamples(url, in: 100..<350) == (100..<350).map { Int16($0) })
        #expect(try WAVFile.readSamples(url, in: 0..<1000) == (0..<1000).map { Int16($0) })
    }

    @Test func rangedReadClampsToFileEnd() throws {
        let url = try ramp(1000, dataBytes: 64_000)
        #expect(try WAVFile.readSamples(url, in: 900..<2000) == (900..<1000).map { Int16($0) })
        #expect(try WAVFile.readSamples(url, in: 2000..<3000).isEmpty)
    }
}
