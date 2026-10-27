import Foundation
import Testing
import AutoNoteCore

@Suite struct ObsidianLinkTests {
    @Test func obsidianLinkEncodesEverythingButUnreserved() {
        let u = ObsidianLink.url(for: URL(filePath: "/Users/a/Vault/Meetings/2026/2026-10-24_1400_定例 #1 & A.md"))
        #expect(u.absoluteString == "obsidian://open?path=%2FUsers%2Fa%2FVault%2FMeetings%2F2026%2F2026-10-24_1400_%E5%AE%9A%E4%BE%8B%20%231%20%26%20A.md")
        #expect(ObsidianLink.url(for: URL(filePath: "/a/b-c.d_e~f+g=h.md")).absoluteString == "obsidian://open?path=%2Fa%2Fb-c.d_e~f%2Bg%3Dh.md")
    }

    @Test func webURLIsNeverSentToObsidian() {
        let web = URL(string: "https://example.com/setup")!, file = URL(filePath: "/tmp/v/会議 #1.md")
        #expect(ObsidianLink.target(for: web, obsidianInstalled: true) == web)
        #expect(ObsidianLink.target(for: file, obsidianInstalled: true) == ObsidianLink.url(for: file))
        #expect(ObsidianLink.target(for: file, obsidianInstalled: false) == file)
    }
}
