import AutoNoteCore
import Foundation
import Testing

@Suite struct DevLiveSummaryArgumentsTests {
    @Test func parsesLiveStateAndClaude() throws {
        let a = try DevLiveSummaryArguments.parse(["l.json", "--state", "s.json", "--claude"])
        #expect(a.live.lastPathComponent == "l.json")
        #expect(a.state?.lastPathComponent == "s.json")
        #expect(a.useClaude)

        let plain = try DevLiveSummaryArguments.parse(["l.json"])
        #expect(plain.live.lastPathComponent == "l.json")
        #expect(plain.state == nil)
        #expect(!plain.useClaude)
    }

    @Test func rejectsBadArguments() {
        for args in [[], ["a", "b"], ["l.json", "--state"], ["l.json", "--bogus"]] {
            #expect(throws: DevLiveSummaryArguments.ParseError.self) {
                try DevLiveSummaryArguments.parse(args)
            }
        }
    }
}
