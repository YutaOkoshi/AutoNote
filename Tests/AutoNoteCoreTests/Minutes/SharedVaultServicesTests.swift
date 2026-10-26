import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct SharedVaultServicesTests {
    @Test func sameFolderSharesInstances() throws {
        let services = SharedVaultServices()
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let folder = try TemporaryDirectory.make()
        let a = services.vaultWriter(outputFolder: folder, paths: paths, now: Date.init)
        let b = services.vaultWriter(outputFolder: folder.appending(path: "x/.."), paths: paths, now: Date.init)
        #expect(a === b)
        #expect(services.configStore(outputFolder: folder, paths: paths)
                === services.configStore(outputFolder: folder, paths: paths))
        #expect(services.configStore(outputFolder: nil, paths: paths)
                === services.configStore(outputFolder: nil, paths: paths))
    }

    @Test func differentFolderOrRootGetsNewInstances() throws {
        let services = SharedVaultServices()
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let otherPaths = AppPaths(root: try TemporaryDirectory.make())
        let folder = try TemporaryDirectory.make()
        let other = try TemporaryDirectory.make()
        let a = services.vaultWriter(outputFolder: folder, paths: paths, now: Date.init)
        #expect(a !== services.vaultWriter(outputFolder: other, paths: paths, now: Date.init))
        #expect(a !== services.vaultWriter(outputFolder: folder, paths: otherPaths, now: Date.init))
        let c = services.configStore(outputFolder: folder, paths: paths)
        #expect(c !== services.configStore(outputFolder: other, paths: paths))
        #expect(c !== services.configStore(outputFolder: nil, paths: paths))
    }
}
