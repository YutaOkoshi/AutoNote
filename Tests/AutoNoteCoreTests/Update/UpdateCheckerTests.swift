import CryptoKit
import Foundation
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

struct UpdateTestFakeFetcher: UpdateFeedFetching {
    var result: Result<Data, URLError>
    func fetch(_ url: URL) async throws -> Data { try result.get() }
}

/// Writes `bytes` as the download.
struct UpdateTestFakeDownloader: ModelDownloading {
    var bytes: Data
    var fails = false
    func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        if fails { throw URLError(.notConnectedToInternet) }
        try bytes.write(to: destination)
        progress(Int64(bytes.count), Int64(bytes.count))
    }
}

/// "Unpacks" by writing an app bundle with the given Info.plist values (or nothing when `appCount` is 0).
struct UpdateTestFakeExtractor: UpdateArchiveExtracting {
    var bundleID = "com.yutaokoshi.autonote"
    var version = "0.7.0"
    var appCount = 1
    func extract(_ zip: URL, into directory: URL) async throws {
        for i in 0..<appCount {
            let app = directory.appending(path: i == 0 ? "AutoNote.app" : "Other\(i).app")
            try writeApp(app, bundleID: bundleID, version: version)
        }
    }
}

func writeApp(_ app: URL, bundleID: String, version: String) throws {
    let contents = app.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appending(path: "Info.plist"))
}

struct UpdateTestFakeSignatures: CodeSignatureChecking {
    var runningRequirement: String? = #"identifier "com.yutaokoshi.autonote" and certificate leaf = H"9d94""#
    var check: CodeSignatureError? = nil
    func designatedRequirement(of app: URL) throws(CodeSignatureError) -> String {
        guard let runningRequirement else { throw .noRequirement(-1) }
        return runningRequirement
    }
    func check(_ app: URL, satisfies requirement: String) throws(CodeSignatureError) {
        if let check { throw check }
    }
}

@Suite struct UpdateCheckerTests {
    let zipBytes = Data("pretend zip".utf8)
    var zipDigest: String { SHA256.hash(data: zipBytes).map { String(format: "%02x", $0) }.joined() }

    func feed(version: String = "0.7.0", digest: String? = nil) -> Data {
        let d = digest ?? zipDigest
        return Data(#"{"tag_name":"v\#(version)","assets":[{"name":"AutoNote-\#(version)-macos-universal.zip","browser_download_url":"https://github.com/YutaOkoshi/AutoNote/releases/download/v\#(version)/AutoNote-\#(version)-macos-universal.zip","digest":"sha256:\#(d)"}]}"#.utf8)
    }

    func checker(dir: URL, feed: Result<Data, URLError>? = nil, download: UpdateTestFakeDownloader? = nil,
                 extractor: UpdateTestFakeExtractor = UpdateTestFakeExtractor(), signatures: UpdateTestFakeSignatures = UpdateTestFakeSignatures(),
                 running: Bool = true) -> UpdateChecker {
        let context = UpdateContext(
            feedURL: URL(string: "https://api.github.com/repos/YutaOkoshi/AutoNote/releases/latest")!,
            policy: .thisRepository, currentVersion: ReleaseVersion("0.6.0")!, bundleID: "com.yutaokoshi.autonote",
            runningApp: running ? URL(filePath: "/Applications/AutoNote.app") : nil,
            directory: dir.appending(path: "updates"))
        return UpdateChecker(context: context, fetcher: UpdateTestFakeFetcher(result: feed ?? .success(self.feed())),
                             downloader: download ?? UpdateTestFakeDownloader(bytes: zipBytes), extractor: extractor,
                             signatures: signatures)
    }

    @Test func newerReleaseIsAvailableAndSameOrOlderIsUpToDate() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .available(let r) = try await checker(dir: dir).check() else { Issue.record("not available"); return }
        #expect(r.version == ReleaseVersion("0.7.0"))
        #expect(try await checker(dir: dir, feed: .success(feed(version: "0.6.0"))).check() == .upToDate(latest: ReleaseVersion("0.6.0")!))
        #expect(try await checker(dir: dir, feed: .success(feed(version: "0.5.9"))).check() == .upToDate(latest: ReleaseVersion("0.5.9")!))
    }

    @Test func networkFailureIsQuiet() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: UpdateFailure.network) { try await checker(dir: dir, feed: .failure(URLError(.timedOut))).check() }
        #expect(!UpdateFailure.network.needsManualUpdate)
    }

    @Test func preparesAVerifiedApp() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = checker(dir: dir)
        guard case .available(let release) = try await c.check() else { Issue.record("not available"); return }
        let staged = try await c.prepare(release)
        #expect(staged.version == ReleaseVersion("0.7.0"))
        #expect(staged.app.lastPathComponent == "AutoNote.app")
        #expect(staged.requirement.contains("certificate leaf"))
        #expect(FileManager.default.fileExists(atPath: staged.app.path))
        // The zip itself is gone once unpacked.
        #expect(!FileManager.default.fileExists(atPath: staged.app.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "download.zip").path))
    }

    @Test func refusesAHashMismatchAndLeavesNothing() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = checker(dir: dir, feed: .success(feed(digest: String(repeating: "0", count: 64))))
        guard case .available(let release) = try await c.check() else { Issue.record("not available"); return }
        await #expect(throws: UpdateFailure.hashMismatch) { try await c.prepare(release) }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "updates/0.7.0").path))
    }

    @Test func refusesADifferentSignerOrABrokenSignature() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (error, expected) in [(CodeSignatureError.requirementNotMet, UpdateFailure.signatureMismatch),
                                  (.invalid(-67061), .signatureInvalid)] {
            let c = checker(dir: dir, signatures: UpdateTestFakeSignatures(check: error))
            guard case .available(let release) = try await c.check() else { Issue.record("not available"); return }
            await #expect(throws: expected) { try await c.prepare(release) }
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "updates/0.7.0").path))
        }
    }

    @Test func refusesAnotherBundleOrAVersionOtherThanTheRelease() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        for extractor in [UpdateTestFakeExtractor(bundleID: "com.example.other"), UpdateTestFakeExtractor(version: "0.6.0"),
                          UpdateTestFakeExtractor(version: "0.8.0")] {
            let c = checker(dir: dir, extractor: extractor)
            guard case .available(let release) = try await c.check() else { Issue.record("not available"); return }
            await #expect(throws: UpdateFailure.bundleMismatch) { try await c.prepare(release) }
        }
        let none = checker(dir: dir, extractor: UpdateTestFakeExtractor(appCount: 0))
        guard case .available(let r1) = try await none.check() else { return }
        await #expect(throws: UpdateFailure.noApp) { try await none.prepare(r1) }
        let two = checker(dir: dir, extractor: UpdateTestFakeExtractor(appCount: 2))
        guard case .available(let r2) = try await two.check() else { return }
        await #expect(throws: UpdateFailure.noApp) { try await two.prepare(r2) }
    }

    @Test func anAdHocOrBareRunningAppNeedsAManualUpdate() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let adHoc = checker(dir: dir, signatures: UpdateTestFakeSignatures(runningRequirement: #"cdhash H"abcd""#))
        guard case .available(let r) = try await adHoc.check() else { return }
        await #expect(throws: UpdateFailure.adHocSigned) { try await adHoc.prepare(r) }
        #expect(UpdateFailure.adHocSigned.needsManualUpdate)
        await #expect(throws: UpdateFailure.notInstalledApp) { try await checker(dir: dir, running: false).prepare(r) }
        await #expect(throws: UpdateFailure.notInstalledApp) {
            try await checker(dir: dir, signatures: UpdateTestFakeSignatures(runningRequirement: nil)).prepare(r)
        }
    }

    @Test func downloadFailureIsReported() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = checker(dir: dir, download: UpdateTestFakeDownloader(bytes: Data(), fails: true))
        guard case .available(let r) = try await c.check() else { return }
        await #expect(throws: UpdateFailure.download) { try await c.prepare(r) }
    }

    @Test func staleVersionFoldersAreRemoved() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let updates = dir.appending(path: "updates")
        for name in ["0.6.5", "0.6.9", "not-a-version"] {
            try FileManager.default.createDirectory(at: updates.appending(path: name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: updates.appending(path: "state.json"))
        let c = checker(dir: dir)
        guard case .available(let r) = try await c.check() else { return }
        _ = try await c.prepare(r)
        let left = try FileManager.default.contentsOfDirectory(atPath: updates.path).sorted()
        #expect(left == ["0.7.0", "not-a-version", "state.json"])
    }

    @Test func writableProblemNamesTheFolder() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appending(path: "AutoNote.app")
        try writeApp(app, bundleID: "x", version: "1")
        #expect(UpdateChecker.writableProblem(app: app) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(UpdateChecker.writableProblem(app: app) == .notWritable(dir.path))
        #expect(UpdateFailure.notWritable(dir.path).needsManualUpdate)
    }

    @Test func currentVersionComesFromTheRunningBundle() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appending(path: "AutoNote.app")
        try writeApp(app, bundleID: "com.yutaokoshi.autonote", version: "9.9.9")
        #expect(UpdateContext.currentVersion(runningApp: app) == ReleaseVersion("9.9.9"))
        #expect(UpdateContext.currentVersion(runningApp: nil) == ReleaseVersion(AutoNoteVersion.current))
        #expect(BundleFacts.enclosingApp(ofExecutable: app.appending(path: "Contents/MacOS/AutoNoteApp"))?.lastPathComponent
            == "AutoNote.app")
        #expect(BundleFacts.enclosingApp(ofExecutable: dir.appending(path: ".build/debug/AutoNoteApp")) == nil)
    }
}

/// The real `SecStaticCode` checks on ad-hoc signed bundles made here (codesign needs no identity for `-`).
@Suite struct SecCodeSignatureCheckerTests {
    func signedApp(_ dir: URL, name: String, marker: String) throws -> URL {
        let app = dir.appending(path: "\(name).app")
        try writeApp(app, bundleID: "com.example.\(name)", version: "1.0")
        let exe = app.appending(path: "Contents/MacOS/\(name)")
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: exe)
        var plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appending(path: "Contents/Info.plist")), format: nil) as! [String: Any]
        plist["CFBundleExecutable"] = name
        plist["Marker"] = marker
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", "--timestamp=none", app.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return app
    }

    @Test func readsTheRequirementAndTellsInvalidFromForeign() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try signedApp(dir, name: "A", marker: "a")
        let b = try signedApp(dir, name: "B", marker: "b")
        let checker = SecCodeSignatureChecker()
        let requirement = try checker.designatedRequirement(of: a)
        #expect(requirement.hasPrefix("cdhash"))
        try checker.check(a, satisfies: requirement)
        #expect(throws: CodeSignatureError.requirementNotMet) { try checker.check(b, satisfies: requirement) }
        // A change after signing breaks the seal.
        try Data("tampered".utf8).write(to: a.appending(path: "Contents/Resources-extra.txt"))
        #expect(throws: (any Error).self) { try checker.check(a, satisfies: requirement) }
        let unsigned = dir.appending(path: "C.app")
        try writeApp(unsigned, bundleID: "c", version: "1")
        #expect(throws: (any Error).self) { try checker.designatedRequirement(of: unsigned) }
    }
}
