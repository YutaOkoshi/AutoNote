import CryptoKit
import Foundation
import Security

// The updater's edges to the outside — HTTP, unzip, code signatures, files — each behind a protocol so the
// decisions in `UpdateChecker` are tested without the network or real signatures.

public enum UpdateFetchError: Error, Equatable, Sendable {
    case http(Int)
}

public protocol UpdateFeedFetching: Sendable {
    /// The body of `GET url`; throws on transport errors and non-2xx answers.
    func fetch(_ url: URL) async throws -> Data
}

/// One plain GET with no cookies or cache, and no information beyond the request itself (spec: anti-goals).
/// Redirects follow `policy` (GitHub hosts only in a release build).
public struct URLSessionFeedFetcher: UpdateFeedFetching {
    private let policy: UpdateURLPolicy
    private let userAgent: String

    public init(policy: UpdateURLPolicy, userAgent: String = UpdateURLPolicy.userAgent) {
        self.policy = policy
        self.userAgent = userAgent
    }

    public func fetch(_ url: URL) async throws -> Data {
        guard policy.allowsRequest(url) else { throw URLError(.unsupportedURL) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: UpdateSessionDelegate(policy: policy), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(UpdateURLPolicy.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw UpdateFetchError.http(http.statusCode) }
        guard policy.allowsRequest(http.url) else { throw URLError(.badServerResponse) }
        return data
    }
}

public protocol UpdateArchiveExtracting: Sendable {
    /// Unpacks the zip at `zip` into the existing, empty directory `directory`.
    func extract(_ zip: URL, into directory: URL) async throws
}

/// `ditto -x -k`, after `UpdateArchive.check` passed on the zip's directory (throws `UpdateArchiveError` otherwise,
/// before anything is written). `ditto` and not `bsdtar`: the release zip is made by `ditto -c -k`, whose `._*`
/// entries only `ditto` folds back into extended attributes; written out as files they would break the seal.
public struct DittoExtractor: UpdateArchiveExtracting {
    public var appName: String
    public var limits: UpdateArchiveLimits

    public init(appName: String = UpdateChecker.archiveAppName, limits: UpdateArchiveLimits = .init()) {
        self.appName = appName
        self.limits = limits
    }

    public func extract(_ zip: URL, into directory: URL) async throws {
        try UpdateArchive.check(UpdateArchive.entries(of: zip), appName: appName, limits: limits)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { c.resume() } else { c.resume(throwing: CocoaError(.fileReadCorruptFile)) }
            }
            do { try process.run() } catch { c.resume(throwing: error) }
        }
    }
}

public enum CodeSignatureError: Error, Equatable, Sendable {
    /// The bundle is unsigned, modified after signing, or its signature is broken.
    case invalid(Int32)
    /// Validly signed, but not by the identity the running app is signed with.
    case requirementNotMet
    /// The running app's own requirement could not be read.
    case noRequirement(Int32)
}

public protocol CodeSignatureChecking: Sendable {
    /// The designated requirement of the signed bundle at `app`, as text
    /// (`identifier "…" and certificate leaf = H"…"` for the self-signed identity).
    func designatedRequirement(of app: URL) throws(CodeSignatureError) -> String
    /// The designated requirement of this process, from the signature the kernel validated when it started
    /// (`SecCodeCopySelf`), not from the bundle on disk, which could have been replaced since.
    func designatedRequirementOfRunningProcess() throws(CodeSignatureError) -> String
    /// Checks that `app` is validly signed (strict, all architectures, nested code) and satisfies `requirement`.
    func check(_ app: URL, satisfies requirement: String) throws(CodeSignatureError)
}

/// `SecStaticCode` checks, the same ones `codesign --verify --strict -R=<requirement>` runs.
public struct SecCodeSignatureChecker: CodeSignatureChecking {
    public init() {}

    public func designatedRequirement(of app: URL) throws(CodeSignatureError) -> String {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw .noRequirement(status) }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw .noRequirement(status) }
        var text: CFString?
        status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text else { throw .noRequirement(status) }
        return text as String
    }

    public func designatedRequirementOfRunningProcess() throws(CodeSignatureError) -> String {
        var me: SecCode?
        var status = SecCodeCopySelf([], &me)
        guard status == errSecSuccess, let me else { throw .noRequirement(status) }
        status = SecCodeCheckValidity(me, [], nil)
        guard status == errSecSuccess else { throw .invalid(status) }
        var requirement: SecRequirement?
        // A SecCode is accepted wherever a SecStaticCode is (both are code objects to the API).
        status = SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &requirement)
        guard status == errSecSuccess, let requirement else { throw .noRequirement(status) }
        var text: CFString?
        status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text else { throw .noRequirement(status) }
        return text as String
    }

    public func check(_ app: URL, satisfies requirementText: String) throws(CodeSignatureError) {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw .invalid(status) }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw .noRequirement(status) }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        // Validity first, without the requirement, so a broken signature and a different signer read differently.
        status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil)
        guard status == errSecSuccess else { throw .invalid(status) }
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        if status == errSecCSReqFailed { throw .requirementNotMet }
        guard status == errSecSuccess else { throw .invalid(status) }
    }
}

public enum FileHash {
    /// SHA-256 of the file as lowercase hex, read in 1 MB chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The parts of an app bundle's `Info.plist` the updater compares.
public struct BundleFacts: Equatable, Sendable {
    public var bundleID: String
    public var shortVersion: String

    public init(bundleID: String, shortVersion: String) {
        self.bundleID = bundleID
        self.shortVersion = shortVersion
    }

    public static func read(_ app: URL) -> BundleFacts? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String,
              let version = dict["CFBundleShortVersionString"] as? String else { return nil }
        return BundleFacts(bundleID: id, shortVersion: version)
    }

    /// The `.app` that contains `executable` (`…/X.app/Contents/MacOS/<exe>`), or nil when it is not inside one
    /// (`swift run`, a bare build product).
    public static func enclosingApp(ofExecutable executable: URL) -> URL? {
        var url = executable.resolvingSymlinksInPath()
        for _ in 0..<3 {
            url = url.deletingLastPathComponent()
        }
        let macOS = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents",
              url.pathExtension == "app" else { return nil }
        return url
    }
}
