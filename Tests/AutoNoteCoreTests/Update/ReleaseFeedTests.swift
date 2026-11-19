import Foundation
import Testing
@testable import AutoNoteCore

@Suite struct ReleaseVersionTests {
    @Test func parsesPlainAndTaggedVersions() {
        #expect(ReleaseVersion("0.6.0")?.components == [0, 6, 0])
        #expect(ReleaseVersion("v1.2.3")?.components == [1, 2, 3])
        #expect(ReleaseVersion("V10")?.components == [10])
    }

    @Test func rejectsAnythingButDottedNumbers() {
        for bad in ["", "v", "0.7.0-beta", "1..2", "1.2.", "latest", "1.2.3.4.5", "１.２", "-1.0", "0x1"] {
            #expect(ReleaseVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func comparesNumericallyPartByPart() throws {
        func v(_ s: String) throws -> ReleaseVersion { try #require(ReleaseVersion(s)) }
        #expect(try v("0.10.0") > v("0.9.9"))
        #expect(try v("1.0.0") > v("0.99.99"))
        #expect(try v("0.6.1") > v("0.6.0"))
        #expect(try v("0.6") == v("0.6.0"))
        #expect(try !(v("0.6.0") < v("0.6")))
        #expect(try Set([v("0.6"), v("0.6.0")]).count == 1)
        #expect(try v("v0.6.0").description == "0.6.0")
    }
}

@Suite struct ReleaseFeedTests {
    static let digest = String(repeating: "ab", count: 32)

    static func json(tag: String = "v0.7.0", draft: Bool = false, prerelease: Bool = false,
                     asset: String? = nil, url: String? = nil, digest: String? = "sha256:" + ReleaseFeedTests.digest) -> Data {
        let name = asset ?? "AutoNote-\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)-macos-universal.zip"
        let href = url ?? "https://github.com/YutaOkoshi/AutoNote/releases/download/\(tag)/\(name)"
        var assetObject: [String: Any] = ["name": name, "browser_download_url": href, "size": 20_000_000]
        if let digest { assetObject["digest"] = digest }
        let object: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": "https://github.com/x",
            "assets": [["name": "other.txt", "browser_download_url": "https://github.com/YutaOkoshi/AutoNote/releases/download/x/other.txt"], assetObject],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func readsTheUniversalZipAndItsDigest() throws {
        let r = try ReleaseFeed.parse(Self.json())
        #expect(r.version == ReleaseVersion("0.7.0"))
        #expect(r.tag == "v0.7.0")
        #expect(r.zipURL.absoluteString == "https://github.com/YutaOkoshi/AutoNote/releases/download/v0.7.0/AutoNote-0.7.0-macos-universal.zip")
        #expect(r.sha256 == Self.digest)
        #expect(r.size == 20_000_000)
    }

    @Test func uppercaseDigestIsNormalised() throws {
        let r = try ReleaseFeed.parse(Self.json(digest: "SHA256:" + Self.digest.uppercased()))
        #expect(r.sha256 == Self.digest)
    }

    @Test func refusesDraftsPrereleasesAndOddTags() {
        #expect(throws: ReleaseFeedError.notStable) { try ReleaseFeed.parse(Self.json(draft: true)) }
        #expect(throws: ReleaseFeedError.notStable) { try ReleaseFeed.parse(Self.json(prerelease: true)) }
        #expect(throws: ReleaseFeedError.badTag("nightly")) { try ReleaseFeed.parse(Self.json(tag: "nightly", asset: "x.zip")) }
        #expect(throws: ReleaseFeedError.malformed) { try ReleaseFeed.parse(Data("{}".utf8)) }
        #expect(throws: ReleaseFeedError.malformed) { try ReleaseFeed.parse(Data("<html>".utf8)) }
    }

    @Test func refusesAMissingAssetOrDigest() {
        #expect(throws: ReleaseFeedError.missingAsset("AutoNote-0.7.0-macos-universal.zip")) {
            try ReleaseFeed.parse(Self.json(asset: "AutoNote-0.7.0.dmg"))
        }
        #expect(throws: ReleaseFeedError.missingDigest) { try ReleaseFeed.parse(Self.json(digest: nil)) }
        #expect(throws: ReleaseFeedError.missingDigest) { try ReleaseFeed.parse(Self.json(digest: "sha1:abcd")) }
        #expect(throws: ReleaseFeedError.missingDigest) { try ReleaseFeed.parse(Self.json(digest: "sha256:zz")) }
    }

    /// The zip must be one of this repository's release downloads over https (Lead: 確認先をこのリポジトリに固定).
    @Test func refusesZipsFromElsewhere() {
        for url in ["http://github.com/YutaOkoshi/AutoNote/releases/download/v0.7.0/a.zip",
                    "https://github.com/someone/AutoNote/releases/download/v0.7.0/a.zip",
                    "https://evil.example/YutaOkoshi/AutoNote/releases/download/v0.7.0/a.zip",
                    "https://github.com/YutaOkoshi/AutoNote/archive/v0.7.0.zip",
                    "https://github.com/YutaOkoshi/AutoNote/releases/download/../../../x/a.zip"] {
            #expect(throws: ReleaseFeedError.foreignURL, "\(url)") { try ReleaseFeed.parse(Self.json(url: url)) }
        }
    }

    @Test func developmentPolicyAcceptsALocalServer() throws {
        let r = try ReleaseFeed.parse(Self.json(url: "http://127.0.0.1:8123/good.zip"), policy: .development)
        #expect(r.zipURL.absoluteString == "http://127.0.0.1:8123/good.zip")
    }
}

@Suite struct UpdateURLPolicyTests {
    @Test func releaseRequestsAndRedirectsStayOnGitHubOverHTTPS() {
        let p = UpdateURLPolicy.thisRepository
        #expect(p.allowsRequest(URL(string: "https://api.github.com/repos/YutaOkoshi/AutoNote/releases/latest")))
        #expect(p.allowsRequest(URL(string: "https://github.com/YutaOkoshi/AutoNote/releases/download/v1/a.zip")))
        #expect(p.allowsRequest(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1")))
        #expect(p.allowsRequest(URL(string: "https://objects.githubusercontent.com/x")))
        #expect(!p.allowsRequest(URL(string: "http://objects.githubusercontent.com/x")))
        #expect(!p.allowsRequest(URL(string: "https://githubusercontent.com.evil.example/x")))
        #expect(!p.allowsRequest(URL(string: "https://evilgithub.com/x")))
        #expect(!p.allowsRequest(nil))
        #expect(p.feedURL?.absoluteString == "https://api.github.com/repos/YutaOkoshi/AutoNote/releases/latest")
    }

    @Test func developmentFeedOnlyInADebugBuildWithTheDataDirectoryOverridden() {
        let env = ["AUTONOTE_DATA_DIR": "/tmp/an", "AUTONOTE_UPDATE_FEED_URL": "http://127.0.0.1:9/latest.json"]
        let dev = UpdateContext.feed(environment: env, debugBuild: true)
        #expect(dev.url.absoluteString == "http://127.0.0.1:9/latest.json")
        #expect(dev.policy == .development)

        let release = UpdateContext.feed(environment: env, debugBuild: false)
        #expect(release.url == UpdateURLPolicy.thisRepository.feedURL)
        #expect(release.policy == .thisRepository)

        let noData = UpdateContext.feed(environment: ["AUTONOTE_UPDATE_FEED_URL": "http://127.0.0.1:9/latest.json"], debugBuild: true)
        #expect(noData.policy == .thisRepository)

        let badScheme = UpdateContext.feed(environment: ["AUTONOTE_DATA_DIR": "/tmp/an", "AUTONOTE_UPDATE_FEED_URL": "file:///etc/passwd"],
                                           debugBuild: true)
        #expect(badScheme.policy == .thisRepository)
    }
}
