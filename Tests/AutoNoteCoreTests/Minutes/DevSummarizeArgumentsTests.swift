import AutoNoteCore
import Foundation
import Testing

@Suite struct DevSummarizeArgumentsTests {
    @Test func parsesAllOptions() throws {
        let a = try DevSummarizeArguments.parse(
            ["--fake", "t.json", "--out", "d", "--minutes", "m.json", "--fail-summary"])
        #expect(a.transcript.lastPathComponent == "t.json")
        #expect(a.out.lastPathComponent == "d")
        #expect(a.minutes?.lastPathComponent == "m.json")
        #expect(a.failSummary)
        #expect(!a.useClaude)
    }

    @Test func requiresFakeAndOut() {
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--minutes", "m.json"])
        }
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--out", "d", "--minutes", "m.json"])
        }
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--bogus"])
        }
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--out"])
        }
    }

    @Test func minutesRequiredUnlessFailOrClaude() throws {
        #expect(throws: DevSummarizeArguments.ParseError.self) {
            try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d"])
        }
        let claude = try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--claude"])
        #expect(claude.useClaude && claude.minutes == nil)
        let failing = try DevSummarizeArguments.parse(["--fake", "t.json", "--out", "d", "--fail-summary"])
        #expect(failing.failSummary && failing.minutes == nil)
    }
}
