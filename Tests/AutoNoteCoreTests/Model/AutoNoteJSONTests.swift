import Foundation
import Testing
@testable import AutoNoteCore

@Test func jsonUsesSnakeCaseAndISO8601() throws {
    struct Probe: Codable, Equatable { var startedAt: Date; var relativePath: String }
    let p = Probe(startedAt: Date(timeIntervalSince1970: 0), relativePath: "a/b")
    let s = String(decoding: try AutoNoteJSON.encoder().encode(p), as: UTF8.self)
    #expect(s.contains(#""started_at" : "1970-01-01T00:00:00.000Z""#))
    #expect(s.contains(#""relative_path" : "a/b""#))
    #expect(try AutoNoteJSON.decoder().decode(Probe.self, from: Data(s.utf8)) == p)
}

@Test func jsonDecodesDatesWithAndWithoutFraction() throws {
    struct Probe: Codable, Equatable { var at: Date }
    let plain = try AutoNoteJSON.decoder().decode(Probe.self, from: Data(#"{"at":"2026-10-24T05:00:00Z"}"#.utf8))
    #expect(plain.at == Date(timeIntervalSince1970: 1_792_818_000))
    let fraction = try AutoNoteJSON.decoder().decode(Probe.self, from: Data(#"{"at":"2026-10-24T05:00:00.250Z"}"#.utf8))
    #expect(fraction.at == Date(timeIntervalSince1970: 1_792_818_000.25))
    #expect(throws: DecodingError.self) { try AutoNoteJSON.decoder().decode(Probe.self, from: Data(#"{"at":"yesterday"}"#.utf8)) }
}
