import Testing
@testable import AutoNoteCore

@Test func overrideDetectionMatchesAppPaths() {
    let env = ["AUTONOTE_DATA_DIR": "/tmp/an-test"]
    #expect(AppIdentity.isDataDirectoryOverridden(env) && AppPaths.resolve(environment: env).root.path == "/tmp/an-test")
    #expect(!AppIdentity.isDataDirectoryOverridden([:]) && !AppIdentity.isDataDirectoryOverridden(["AUTONOTE_DATA_DIR": ""]))
    #expect(AppIdentity.bundleID == "com.yutaokoshi.autonote")
}
