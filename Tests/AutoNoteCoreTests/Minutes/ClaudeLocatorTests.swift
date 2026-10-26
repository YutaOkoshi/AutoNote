import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct ClaudeLocatorTests {
    private let home = URL(fileURLWithPath: "/Users/fictional")

    @Test func fallbackCandidatesAreInSearchOrder() {
        #expect(ClaudeLocator.fallbackCandidates == [
            "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
    }

    @Test func prefersLoginShellResult() async {
        let found = await ClaudeLocator.locate(
            home: home, loginShellLookup: { "/x/claude" }, isExecutable: { _ in true })
        #expect(found == "/x/claude")
    }

    @Test func ignoresLoginShellResultThatIsNotExecutable() async {
        let found = await ClaudeLocator.locate(
            home: home, loginShellLookup: { "/x/claude" }, isExecutable: { $0 == "/usr/local/bin/claude" })
        #expect(found == "/usr/local/bin/claude")
    }

    @Test func fallsBackToCandidatesInOrder() async {
        let local = "/Users/fictional/.local/bin/claude"
        let found = await ClaudeLocator.locate(
            home: home, loginShellLookup: { nil },
            isExecutable: { $0 == local || $0 == "/opt/homebrew/bin/claude" })
        #expect(found == local)

        let brew = await ClaudeLocator.locate(
            home: home, loginShellLookup: { nil },
            isExecutable: { $0 == "/opt/homebrew/bin/claude" || $0 == "/usr/local/bin/claude" })
        #expect(brew == "/opt/homebrew/bin/claude")

        let claudeLocal = await ClaudeLocator.locate(
            home: home, loginShellLookup: { nil }, isExecutable: { $0 == "/Users/fictional/.claude/local/claude" })
        #expect(claudeLocal == "/Users/fictional/.claude/local/claude")

        let none = await ClaudeLocator.locate(home: home, loginShellLookup: { nil }, isExecutable: { _ in false })
        #expect(none == nil)
    }

    @Test func fillDefaultPathOnlyWhenUnset() async throws {
        let store = SettingsStore(paths: AppPaths(root: try TemporaryDirectory.make()))
        let filled = try await ClaudeLocator.fillDefaultPath(store, locate: { "/z/claude" })
        #expect(filled == "/z/claude")
        #expect(try await store.load().claudePath == "/z/claude")

        let other = SettingsStore(paths: AppPaths(root: try TemporaryDirectory.make()))
        try await other.update { $0.claudePath = "/y/claude" }
        let called = LocateCalledFlag()
        let kept = try await ClaudeLocator.fillDefaultPath(other, locate: { called.set(); return "/z/claude" })
        #expect(kept == "/y/claude")
        #expect(called.value == false)
        #expect(try await other.load().claudePath == "/y/claude")
    }

    @Test func fillDefaultPathLeavesNilWhenNotFound() async throws {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let store = SettingsStore(paths: paths)
        let filled = try await ClaudeLocator.fillDefaultPath(store, locate: { nil })
        #expect(filled == nil)
        #expect(try await store.load().claudePath == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.settingsFile.path))
    }

    @Test func childPathStartsWithClaudeDirectory() {
        let env = ClaudeLocator.childEnvironment(
            claudePath: "/x/claude", base: ["PATH": "/opt/foo/bin", "HOME": "/Users/fictional"])
        #expect(env["PATH"] == "/x:/usr/bin:/bin:/usr/sbin:/sbin:/opt/foo/bin")
        #expect(env["PATH"]?.hasPrefix("/x:/usr/bin:/bin:/usr/sbin:/sbin:") == true)
        #expect(env["HOME"] == "/Users/fictional")
    }

    @Test func childPathWithoutBasePath() {
        let env = ClaudeLocator.childEnvironment(claudePath: "/x/claude", base: [:])
        #expect(env["PATH"] == "/x:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func loginShellLookupReturnsAbsolutePathOrNil() async {
        // Does not depend on a real `claude` being installed: only the shape of the result is checked.
        let start = ContinuousClock.now
        let found = await ClaudeLocator.loginShellLookup()
        #expect(ContinuousClock.now - start < .seconds(10))
        if let found { #expect(found.hasPrefix("/")); #expect(!found.contains("\n")) }
    }
}

private final class LocateCalledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
