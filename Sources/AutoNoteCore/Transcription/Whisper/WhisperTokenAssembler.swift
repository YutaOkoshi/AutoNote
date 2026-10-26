/// whisper's byte-level BPE tokens can split a multi-byte UTF-8 character. This joins the raw bytes of
/// consecutive tokens until they decode as valid UTF-8, and emits one `TimedToken` spanning them
/// (start = first token's t0, end = last token's t1). Valid tokens pass through unchanged.
struct WhisperTokenAssembler {
    private var pending: [UInt8] = []
    private var start = 0.0
    private var end = 0.0

    /// Times are seconds.
    mutating func append(bytes: [UInt8], t0: Double, t1: Double) -> [TimedToken] {
        if pending.isEmpty { start = t0 }
        pending += bytes
        end = t1
        guard let text = String(validating: pending, as: UTF8.self) else { return [] }
        pending.removeAll()
        return [TimedToken(start: start, end: end, text: text)]
    }

    /// Emits what is left (decoded with replacement characters) at the end of a segment.
    mutating func flush() -> [TimedToken] {
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll() }
        return [TimedToken(start: start, end: end, text: String(decoding: pending, as: UTF8.self))]
    }
}
