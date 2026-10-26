import Foundation

public struct IPCDecodeFailure: Error, Equatable {
    public var id: Int?
    public var error: IPCError

    public init(id: Int?, error: IPCError) {
        self.id = id
        self.error = error
    }
}

/// JSON-lines framing: one JSON object per line, `\n`-terminated, snake_case keys, nil fields omitted.
public enum IPCCodec {
    public static func encode<T: Encodable>(_ v: T) throws -> Data {
        var data = try AutoNoteJSON.compactEncoder().encode(v)
        data.append(0x0A)
        return data
    }

    private struct Envelope: Decodable {
        var id: Int?
        var cmd: String?
    }

    public static func decodeRequest(_ line: Data) throws(IPCDecodeFailure) -> IPCRequest {
        let decoder = AutoNoteJSON.decoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else {
            throw IPCDecodeFailure(id: nil, error: IPCError(code: .badRequest, message: "JSON として読めません"))
        }
        guard let cmd = envelope.cmd else {
            throw IPCDecodeFailure(id: envelope.id, error: IPCError(code: .badRequest, message: "cmd がありません"))
        }
        guard IPCCommand(rawValue: cmd) != nil else {
            throw IPCDecodeFailure(id: envelope.id, error: IPCError(code: .unknownCommand, message: "知らないコマンドです: \(cmd)"))
        }
        do {
            return try decoder.decode(IPCRequest.self, from: line)
        } catch {
            throw IPCDecodeFailure(id: envelope.id, error: IPCError(code: .badRequest, message: "リクエストの形式が正しくありません"))
        }
    }

    public static func decodeResponse(_ line: Data) throws -> IPCResponse {
        try AutoNoteJSON.decoder().decode(IPCResponse.self, from: line)
    }
}

/// Splits a byte stream into `\n`-terminated lines, keeping a trailing partial line for the next chunk.
public struct LineBuffer: Sendable {
    public static let maxLineBytes = 1 << 20

    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) throws(IPCError) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending = Data(pending[pending.index(after: nl)...])
            if line.count > Self.maxLineBytes { throw overlong() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if pending.count > Self.maxLineBytes { throw overlong() }
        return lines
    }

    private mutating func overlong() -> IPCError {
        pending = Data()
        return IPCError(code: .badRequest, message: "1 行が長すぎます")
    }
}
