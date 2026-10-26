import Foundation

public protocol ModelDownloading: Sendable {
    /// Downloads `url` to `destination` (replacing any file there). `progress` receives (bytesWritten, bytesExpected).
    func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws
}

public struct URLSessionModelDownloader: ModelDownloading {
    public init() {}

    public func download(
        _ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        let delegate = ProgressDelegate(progress)
        let (temp, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // The async download API hands back the file; nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
