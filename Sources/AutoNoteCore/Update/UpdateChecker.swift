import Foundation

/// Why a check or a download did not end in an update ready to install. `message` is what the settings show.
public enum UpdateFailure: Error, Equatable, Sendable {
    /// No connection, a time-out, or the API's rate limit: tried again at the next check, quietly.
    case network
    case feed(ReleaseFeedError)
    case download
    case hashMismatch
    case extract
    /// The zip holds no single `.app`.
    case noApp
    case signatureInvalid
    /// Signed, but not with the identity the running app has (a tampered or foreign build).
    case signatureMismatch
    /// The bundle identifier or the version in the downloaded app is not what the release says.
    case bundleMismatch
    /// The running app is not inside an `.app`, or its own signature cannot be read.
    case notInstalledApp
    /// The running app is ad-hoc signed (its requirement is its own hash), so no other build can ever satisfy it.
    case adHocSigned
    /// The folder that holds the app cannot be written.
    case notWritable(String)
    /// The helper could not swap the app and put the old one back.
    case installFailed(version: String, reason: String)

    /// True when an automatic update can never succeed from here: the person has to replace the app by hand.
    public var needsManualUpdate: Bool {
        switch self {
        case .notInstalledApp, .adHocSigned, .notWritable: true
        default: false
        }
    }

    public var message: String {
        switch self {
        case .network: "更新を確認できませんでした（通信できないか、確認の回数の上限です）。次の確認で再試行します"
        case .feed(.missingDigest): "最新版の情報に SHA-256 が無いため、取得しませんでした"
        case .feed: "最新版の情報を読めませんでした"
        case .download: "最新版をダウンロードできませんでした"
        case .hashMismatch: "ダウンロードしたファイルの SHA-256 が最新版の情報と合わないため、入れ替えませんでした"
        case .extract, .noApp: "ダウンロードしたファイルを展開できませんでした"
        case .signatureInvalid: "ダウンロードしたアプリの署名が正しくないため、入れ替えませんでした"
        case .signatureMismatch: "ダウンロードしたアプリの署名がこのアプリと違うため、入れ替えませんでした"
        case .bundleMismatch: "ダウンロードしたアプリが AutoNote の新しい版ではないため、入れ替えませんでした"
        case .notInstalledApp: "このアプリは .app として動いていないため、自動では入れ替えられません"
        case .adHocSigned: "この版は自動アップデートに対応した署名ではありません。GitHub のリリースから手動で入れ替えてください"
        case .notWritable(let folder): "「\(folder)」に書き込めないため、手動での更新が必要です"
        case .installFailed(let version, let reason): "\(version) への入れ替えに失敗したため、元の版に戻しました（\(reason)）"
        }
    }
}

/// An update downloaded, checked and unpacked, waiting to be swapped in.
public struct StagedUpdate: Equatable, Sendable {
    public var version: ReleaseVersion
    /// The unpacked `.app` inside the updates directory.
    public var app: URL
    /// The running app's designated requirement the staged app was checked against (the helper checks it again).
    public var requirement: String
}

public enum UpdateCheckOutcome: Equatable, Sendable {
    case upToDate(latest: ReleaseVersion)
    case available(UpdateRelease)
}

/// Where the updater looks and what it compares against.
public struct UpdateContext: Sendable {
    public var feedURL: URL
    /// `.thisRepository` in every release build; `.development` only for a debug build's development feed.
    public var policy: UpdateURLPolicy
    public var currentVersion: ReleaseVersion
    public var bundleID: String
    /// The running `.app`; nil when the process is not inside one.
    public var runningApp: URL?
    /// `<data>/updates`: downloads, unpacked apps, the state and the helper's result.
    public var directory: URL

    public init(feedURL: URL, policy: UpdateURLPolicy, currentVersion: ReleaseVersion, bundleID: String, runningApp: URL?,
                directory: URL) {
        self.feedURL = feedURL
        self.policy = policy
        self.currentVersion = currentVersion
        self.bundleID = bundleID
        self.runningApp = runningApp
        self.directory = directory
    }

    public static let feedEnvironmentKey = "AUTONOTE_UPDATE_FEED_URL"

    /// The feed and its URL policy. `AUTONOTE_UPDATE_FEED_URL` counts only in a debug build (`debugBuild`, the
    /// caller's `#if DEBUG`) with the data directory overridden (development and E2E); a release build always reads
    /// this repository's `releases/latest` under `.thisRepository`, whatever the environment says.
    public static func feed(environment: [String: String], debugBuild: Bool) -> (url: URL, policy: UpdateURLPolicy) {
        if debugBuild, AppIdentity.isDataDirectoryOverridden(environment),
           let raw = environment[feedEnvironmentKey], !raw.isEmpty, let url = URL(string: raw),
           url.scheme == "http" || url.scheme == "https" {
            return (url, .development)
        }
        return (UpdateURLPolicy.thisRepository.feedURL!, .thisRepository)
    }

    /// `#if DEBUG` of the module that calls it: true only in a debug build.
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The version to compare with: the running bundle's `CFBundleShortVersionString` when there is one (it equals
    /// `AutoNoteVersion.current` in every release; E2E item 5b checks that), else `AutoNoteVersion.current`.
    public static func currentVersion(runningApp: URL?) -> ReleaseVersion {
        if let app = runningApp, let facts = BundleFacts.read(app), let v = ReleaseVersion(facts.shortVersion) { return v }
        return ReleaseVersion(AutoNoteVersion.current) ?? ReleaseVersion("0")!
    }
}

/// Check → download → SHA-256 → unpack → signature, requirement, bundle id and version. Every step that fails
/// leaves nothing to install.
public struct UpdateChecker: Sendable {
    public let context: UpdateContext
    private let fetcher: any UpdateFeedFetching
    private let downloader: any ModelDownloading
    private let extractor: any UpdateArchiveExtracting
    private let signatures: any CodeSignatureChecking

    public init(context: UpdateContext, fetcher: (any UpdateFeedFetching)? = nil,
                downloader: (any ModelDownloading)? = nil,
                extractor: any UpdateArchiveExtracting = DittoExtractor(),
                signatures: any CodeSignatureChecking = SecCodeSignatureChecker()) {
        self.context = context
        self.fetcher = fetcher ?? URLSessionFeedFetcher(policy: context.policy)
        self.downloader = downloader ?? UpdateDownloader(policy: context.policy)
        self.extractor = extractor
        self.signatures = signatures
    }

    public func check() async throws(UpdateFailure) -> UpdateCheckOutcome {
        let data: Data
        do { data = try await fetcher.fetch(context.feedURL) } catch { throw .network }
        let release: UpdateRelease
        do { release = try ReleaseFeed.parse(data, policy: context.policy) } catch { throw .feed(error) }
        return release.version > context.currentVersion ? .available(release) : .upToDate(latest: release.version)
    }

    /// The running app's requirement, refused up front when it can never match another build.
    public func runningRequirement() throws(UpdateFailure) -> (app: URL, requirement: String) {
        guard let app = context.runningApp else { throw .notInstalledApp }
        let requirement: String
        do { requirement = try signatures.designatedRequirement(of: app) } catch { throw .notInstalledApp }
        if requirement.hasPrefix("cdhash") { throw .adHocSigned }
        return (app, requirement)
    }

    /// Whether the folder holding the running app (and the app itself) can be written, which the swap needs.
    public static func writableProblem(app: URL, fileManager: FileManager = .default) -> UpdateFailure? {
        let folder = app.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path), fileManager.isWritableFile(atPath: app.path) else {
            return .notWritable(folder.path)
        }
        return nil
    }

    /// Downloads and checks `release` into `<directory>/<version>/`, removing what earlier versions left there.
    public func prepare(_ release: UpdateRelease,
                        progress: @Sendable @escaping (Int64, Int64) -> Void = { _, _ in }) async throws(UpdateFailure) -> StagedUpdate {
        let (_, requirement) = try runningRequirement()
        let fm = FileManager.default
        let work = context.directory.appending(path: release.version.description, directoryHint: .isDirectory)
        removeStaleDownloads(keeping: work)
        try? fm.removeItem(at: work)
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch { throw .download }

        let zip = work.appending(path: "download.zip")
        do { try await downloader.download(release.zipURL, to: zip, progress: progress) } catch { throw .download }
        let digest: String
        do { digest = try FileHash.sha256(of: zip) } catch { throw .download }
        guard digest == release.sha256 else {
            try? fm.removeItem(at: work)
            throw .hashMismatch
        }

        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await extractor.extract(zip, into: unpacked)
        } catch {
            try? fm.removeItem(at: work)
            throw .extract
        }
        try? fm.removeItem(at: zip)
        let apps = ((try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            try? fm.removeItem(at: work)
            throw .noApp
        }

        do {
            try signatures.check(app, satisfies: requirement)
        } catch .requirementNotMet {
            try? fm.removeItem(at: work)
            throw .signatureMismatch
        } catch {
            try? fm.removeItem(at: work)
            throw .signatureInvalid
        }
        guard let facts = BundleFacts.read(app), facts.bundleID == context.bundleID,
              let version = ReleaseVersion(facts.shortVersion), version == release.version,
              version > context.currentVersion else {
            try? fm.removeItem(at: work)
            throw .bundleMismatch
        }
        return StagedUpdate(version: version, app: app, requirement: requirement)
    }

    /// Deletes version folders under the updates directory other than `keeping` (the cache never grows).
    public func removeStaleDownloads(keeping: URL? = nil) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: context.directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let keeping, entry.standardizedFileURL == keeping.standardizedFileURL { continue }
            if ReleaseVersion(entry.lastPathComponent) != nil { try? fm.removeItem(at: entry) }
        }
    }
}
