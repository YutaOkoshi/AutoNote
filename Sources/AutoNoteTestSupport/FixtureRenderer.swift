import Foundation
import AutoNoteCore

public enum FixtureRenderer {
    /// Renders every fixture meeting into `vault` and rebuilds the index.
    /// Returns the relative paths written (including `_index.md`).
    public static func render(fixtures: URL = FixtureLibrary.defaultDirectory, into vault: URL) async throws -> [String] {
        let dictionary = try FixtureLibrary.dictionary(in: fixtures)
        let finalizer = TranscriptFinalizer(dictionary: dictionary, fillerRemoval: true)
        let state = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: state) }
        let writer = VaultWriter(outputFolder: vault, paths: AppPaths(root: state))
        var written: [String] = []
        for meeting in try FixtureLibrary.meetings(in: fixtures) {
            let (_, final) = finalizer.finalize(meeting.parts, source: meeting.manifest.source,
                                                engine: FixtureLibrary.engine, language: meeting.manifest.language)
            let document = MeetingDocument(
                manifest: meeting.manifest, transcript: final, minutes: meeting.minutes,
                frontmatter: FrontmatterTemplate(text: FrontmatterTemplate.defaultText),
                appVersion: "0.1.0", timeZone: FixtureLibrary.timeZone)
            if case .written(let url) = try await writer.write(document, policy: .force) {
                written.append(relativePath(url, in: vault))
            }
        }
        written.append(relativePath(try await writer.rebuildIndex(), in: vault))
        return written
    }

    /// Relative `.md` paths that differ between the two trees or exist in only one (empty means identical).
    public static func compare(_ vault: URL, expected: URL) throws -> [String] {
        let actual = try markdownFiles(in: vault), wanted = try markdownFiles(in: expected)
        var differing: [String] = []
        for path in Set(actual.keys).union(wanted.keys).sorted() {
            guard let a = actual[path], let w = wanted[path] else { differing.append(path); continue }
            if try Data(contentsOf: a) != Data(contentsOf: w) { differing.append(path) }
        }
        return differing
    }

    private static func markdownFiles(in root: URL) throws -> [String: URL] {
        let base = root.resolvingSymlinksInPath()
        var files: [String: URL] = [:]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return files }
        for case let url as URL in walker where url.pathExtension == "md" {
            files[relativePath(url, in: base)] = url
        }
        return files
    }

    private static func relativePath(_ url: URL, in root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
}
