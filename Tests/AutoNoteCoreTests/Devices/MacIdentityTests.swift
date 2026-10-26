import Testing
import Foundation
@testable import AutoNoteCore

@Suite struct MacIdentityTests {
    @Test func systemMacIdentityIsStable() {
        let provider = SystemMacIdentityProvider()
        let first = provider.current(), second = provider.current()
        #expect(first == second)
        #expect(!first.id.isEmpty)
        #expect(!first.name.isEmpty)
    }
}
