import Testing
@testable import AutoNoteCore

@Test func versionIsSemver() {
    #expect(AutoNoteVersion.current.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
}
