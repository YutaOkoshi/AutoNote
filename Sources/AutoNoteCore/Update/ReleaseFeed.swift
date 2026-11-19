import Foundation

/// The newest release as the updater needs it: its version, the universal zip and that zip's SHA-256.
public struct UpdateRelease: Equatable, Sendable {
    public var version: ReleaseVersion
    public var tag: String
    public var zipURL: URL
    /// Lowercase hex.
    public var sha256: String
    public var size: Int?

    public init(version: ReleaseVersion, tag: String, zipURL: URL, sha256: String, size: Int? = nil) {
        self.version = version
        self.tag = tag
        self.zipURL = zipURL
        self.sha256 = sha256
        self.size = size
    }
}

public enum ReleaseFeedError: Error, Equatable, Sendable {
    /// Not the JSON of one GitHub release.
    case malformed
    /// A draft or a pre-release: never installed automatically.
    case notStable
    /// The tag is not a plain version (`ReleaseVersion`).
    case badTag(String)
    /// No `AutoNote-<version>-macos-universal.zip` among the assets.
    case missingAsset(String)
    /// The asset has no `sha256:` digest, so the download could not be checked.
    case missingDigest
    /// The download URL is not one of this repository's release downloads over https (`UpdateURLPolicy`).
    case foreignURL
}

/// Reads `GET /repos/<owner>/<repo>/releases/latest` (GitHub REST API). The asset name follows `release.yml`:
/// `AutoNote-<version>-macos-universal.zip`, where the tag is `v<version>`.
public enum ReleaseFeed {
    public static func assetName(version: String) -> String { "AutoNote-\(version)-macos-universal.zip" }

    private struct Release: Decodable {
        var tagName: String
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]
    }

    private struct Asset: Decodable {
        var name: String
        var browserDownloadUrl: String
        var digest: String?
        var size: Int?
    }

    public static func parse(_ data: Data, policy: UpdateURLPolicy = .thisRepository) throws(ReleaseFeedError) -> UpdateRelease {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data) else { throw .malformed }
        if release.draft == true || release.prerelease == true { throw .notStable }
        guard let version = ReleaseVersion(release.tagName) else { throw .badTag(release.tagName) }
        // The zip is named after the version as release.yml writes it: the tag without its `v`.
        let plain = release.tagName.hasPrefix("v") || release.tagName.hasPrefix("V")
            ? String(release.tagName.dropFirst()) : release.tagName
        let name = assetName(version: plain)
        guard let asset = release.assets.first(where: { $0.name == name }),
              let url = URL(string: asset.browserDownloadUrl) else { throw .missingAsset(name) }
        guard policy.allowsAsset(url) else { throw .foreignURL }
        guard let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") else { throw .missingDigest }
        let hex = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { throw .missingDigest }
        return UpdateRelease(version: version, tag: release.tagName, zipURL: url, sha256: hex, size: asset.size)
    }
}
