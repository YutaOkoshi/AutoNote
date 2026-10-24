import Testing
@testable import AutoNoteCore

@Test func versionIsSemver() {
    #expect(AutoNoteVersion.current == "0.1.0")
}
