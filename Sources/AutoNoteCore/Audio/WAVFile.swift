import Foundation

public struct WAVInfo: Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var dataBytes: Int
    public var durationSeconds: Double

    public init(sampleRate: Int, channels: Int, bitsPerSample: Int, dataBytes: Int, durationSeconds: Double) {
        self.sampleRate = sampleRate; self.channels = channels; self.bitsPerSample = bitsPerSample
        self.dataBytes = dataBytes; self.durationSeconds = durationSeconds
    }
}

public enum WAVFileError: Error, Equatable, Sendable {
    case invalidHeader
}

public enum WAVFile {
    public static let headerSize = 44

    public static func header(sampleRate: Int, channels: Int, bitsPerSample: Int, dataBytes: Int) -> Data {
        var d = Data(capacity: headerSize)
        let blockAlign = channels * bitsPerSample / 8
        d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(UInt32(truncatingIfNeeded: 36 + dataBytes)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16))
        d.append(le16(1)); d.append(le16(UInt16(channels)))
        d.append(le32(UInt32(sampleRate))); d.append(le32(UInt32(sampleRate * blockAlign)))
        d.append(le16(UInt16(blockAlign))); d.append(le16(UInt16(bitsPerSample)))
        d.append(contentsOf: Array("data".utf8)); d.append(le32(UInt32(truncatingIfNeeded: dataBytes)))
        return d
    }

    public static func info(_ url: URL) throws -> WAVInfo {
        let h = try readHeader(url)
        return makeInfo(h, dataBytes: h.dataBytes)
    }

    public static func readSamples(_ url: URL) throws -> [Int16] {
        try readSamples(url, in: 0..<sampleCount(url))
    }

    /// Number of 16-bit samples in the data chunk (header size, clamped to the file length).
    public static func sampleCount(_ url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try sampleCount(handle)
    }

    /// Reads `range` (clamped to `0..<sampleCount`) with a file handle, never holding the whole file.
    public static func readSamples(_ url: URL, in range: Range<Int>) throws -> [Int16] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try sampleCount(handle)
        let lower = min(max(range.lowerBound, 0), total)
        let upper = min(max(range.upperBound, lower), total)
        let count = upper - lower
        guard count > 0 else { return [] }
        var out = [Int16](repeating: 0, count: count)
        try handle.seek(toOffset: UInt64(headerSize + 2 * lower))
        let chunkBytes = 1 << 20
        var written = 0 // bytes
        let totalBytes = count * 2
        try out.withUnsafeMutableBytes { dst in
            while written < totalBytes {
                guard let chunk = try handle.read(upToCount: min(chunkBytes, totalBytes - written)),
                      !chunk.isEmpty else { break }
                chunk.withUnsafeBytes { src in
                    dst.baseAddress!.advanced(by: written).copyMemory(from: src.baseAddress!, byteCount: chunk.count)
                }
                written += chunk.count
            }
        }
        if written < totalBytes { out.removeLast(count - written / 2) }
        return out
    }

    private static func sampleCount(_ handle: FileHandle) throws -> Int {
        let length = Int(try handle.seekToEnd())
        guard length >= headerSize else { throw WAVFileError.invalidHeader }
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: headerSize), head.count == headerSize else {
            throw WAVFileError.invalidHeader
        }
        let h = try parse(head)
        let available = length - headerSize
        let bytes = (h.dataBytes > 0 ? min(h.dataBytes, available) : available) & ~1
        return bytes / 2
    }

    /// Rewrites the RIFF/data size fields from the actual file length. Nil for files shorter than a header.
    public static func repairHeader(_ url: URL) throws -> WAVInfo? {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        guard length >= headerSize else { return nil }
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: headerSize), head.count == headerSize else { return nil }
        let h = try parse(head)
        let dataBytes = length - headerSize
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(sampleRate: h.sampleRate, channels: h.channels,
                                            bitsPerSample: h.bitsPerSample, dataBytes: dataBytes))
        return makeInfo(h, dataBytes: dataBytes)
    }

    // MARK: - Private

    private struct Parsed { var sampleRate: Int; var channels: Int; var bitsPerSample: Int; var dataBytes: Int }

    private static func readHeader(_ url: URL) throws -> Parsed {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: headerSize), head.count == headerSize else {
            throw WAVFileError.invalidHeader
        }
        return try parse(head)
    }

    private static func parse(_ d: Data) throws -> Parsed {
        let b = [UInt8](d)
        guard b.count >= headerSize, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x41, 0x56, 0x45],
              b[36..<40] == [0x64, 0x61, 0x74, 0x61] else { throw WAVFileError.invalidHeader }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        return Parsed(sampleRate: u32(24), channels: u16(22), bitsPerSample: u16(34), dataBytes: u32(40))
    }

    private static func makeInfo(_ h: Parsed, dataBytes: Int) -> WAVInfo {
        let frameBytes = max(1, h.channels * h.bitsPerSample / 8)
        let seconds = h.sampleRate > 0 ? Double(dataBytes / frameBytes) / Double(h.sampleRate) : 0
        return WAVInfo(sampleRate: h.sampleRate, channels: h.channels, bitsPerSample: h.bitsPerSample,
                       dataBytes: dataBytes, durationSeconds: seconds)
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
