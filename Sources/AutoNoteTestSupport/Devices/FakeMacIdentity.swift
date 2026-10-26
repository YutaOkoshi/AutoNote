import Foundation
import AutoNoteCore

public struct FakeMacIdentity: MacIdentityProviding {
    public var identity: MacIdentity

    public init(_ identity: MacIdentity = MacIdentity(id: "FAKE-MAC-ID", name: "Fictional Mac")) {
        self.identity = identity
    }

    public func current() -> MacIdentity { identity }
}
