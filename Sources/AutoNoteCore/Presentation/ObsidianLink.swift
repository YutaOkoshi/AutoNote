import Foundation

/// `obsidian://open?path=<absolute path>` for a Vault file.
public enum ObsidianLink {
    /// ASCII letters, digits and `-._~` only. `CharacterSet.alphanumerics` would also keep kanji, so it is not used.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func url(for file: URL) -> URL {
        let path = file.path(percentEncoded: false)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        return URL(string: "obsidian://open?path=\(encoded)")!
    }
}
