import Foundation

/// Which URLs the updater may talk to. A release build only ever uses `.github`: the feed is this repository's
/// `releases/latest`, the zip is one of its release downloads, everything is HTTPS, and a redirect may only lead to
/// a GitHub host (the download goes github.com → release-assets.githubusercontent.com). `.development` (any http(s)
/// URL) exists only in debug builds with the data directory overridden (`UpdateContext.feed(environment:)`).
public enum UpdateURLPolicy: Equatable, Sendable {
    case github(owner: String, repo: String)
    case development

    public static let thisRepository = UpdateURLPolicy.github(owner: "YutaOkoshi", repo: "AutoNote")

    /// GitHub's API needs a User-Agent; it names the app only (no version, no machine), so the request says nothing
    /// beyond "is there a newer release".
    public static let userAgent = "AutoNote"
    /// Sent instead of the Mac's languages (URLSession would add them), so the request says nothing about the Mac.
    public static let acceptLanguage = "en"

    static let githubHosts: Set<String> = ["github.com", "api.github.com"]

    /// A host GitHub serves release metadata or assets from.
    public static func isGitHubHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return githubHosts.contains(host) || host.hasSuffix(".githubusercontent.com")
    }

    /// The feed for this policy, unless a development feed is given.
    public var feedURL: URL? {
        switch self {
        case .github(let owner, let repo): URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
        case .development: nil
        }
    }

    /// Whether the release zip at `url` may be downloaded: `https://github.com/<owner>/<repo>/releases/download/…`.
    public func allowsAsset(_ url: URL) -> Bool {
        switch self {
        case .development:
            return url.scheme == "http" || url.scheme == "https"
        case .github(let owner, let repo):
            guard url.scheme == "https", url.host?.lowercased() == "github.com" else { return false }
            let prefix = "/\(owner)/\(repo)/releases/download/".lowercased()
            return url.path.lowercased().hasPrefix(prefix) && !url.path.contains("/../")
        }
    }

    /// Whether a redirect (or the first request) may go to `url`.
    public func allowsRequest(_ url: URL?) -> Bool {
        guard let url else { return false }
        switch self {
        case .development: return url.scheme == "http" || url.scheme == "https"
        case .github: return url.scheme == "https" && Self.isGitHubHost(url.host)
        }
    }
}

/// Refuses redirects the policy does not allow and reports download progress.
final class UpdateSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let policy: UpdateURLPolicy
    private let progress: (@Sendable (Int64, Int64) -> Void)?

    init(policy: UpdateURLPolicy, progress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.policy = policy
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // nil stops at the redirect: the 3xx answer comes back and the caller treats it as a failure.
        completionHandler(policy.allowsRequest(request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// The zip download, under the same redirect rules as the feed.
public struct UpdateDownloader: ModelDownloading {
    private let policy: UpdateURLPolicy

    private static let userAgentValue = UpdateURLPolicy.userAgent

    public init(policy: UpdateURLPolicy) { self.policy = policy }

    public func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        guard policy.allowsRequest(url) else { throw URLError(.unsupportedURL) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let delegate = UpdateSessionDelegate(policy: policy, progress: progress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgentValue, forHTTPHeaderField: "User-Agent")
        request.setValue(UpdateURLPolicy.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        let (temp, response) = try await session.download(for: request)
        let fm = FileManager.default
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              policy.allowsRequest(http.url) else {
            try? fm.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
    }
}
