import Testing
@testable import AutoNoteCore

@Test func overrideDetectionMatchesAppPaths() {
    let env = ["AUTONOTE_DATA_DIR": "/tmp/an-test"]
    #expect(AppIdentity.isDataDirectoryOverridden(env) && AppPaths.resolve(environment: env).root.path == "/tmp/an-test")
    #expect(!AppIdentity.isDataDirectoryOverridden([:]) && !AppIdentity.isDataDirectoryOverridden(["AUTONOTE_DATA_DIR": ""]))
    #expect(AppIdentity.bundleID == "com.yutaokoshi.autonote")
}

@Test func devMenuOnlyForDevelopmentLaunches() {
    // 「開発」メニュー（TCC 確認）は一般の利用者には出さない: AUTONOTE_DATA_DIR の起動か DEBUG ビルドだけ
    #expect(!AppIdentity.showsDevMenu([:], debugBuild: false))
    #expect(!AppIdentity.showsDevMenu(["AUTONOTE_DATA_DIR": ""], debugBuild: false))
    #expect(AppIdentity.showsDevMenu(["AUTONOTE_DATA_DIR": "/tmp/an-test"], debugBuild: false))
    #expect(AppIdentity.showsDevMenu([:], debugBuild: true))
}
