import Foundation

// The downloaded zip is untrusted until its signature is checked, and the signature can only be checked after it is
// unpacked. So the zip is checked twice around `ditto` (review M1): its directory before (names, kinds, sizes, so
// nothing is written outside the unpack folder and no zip bomb fills the disk), and the unpacked tree after (one real
// `.app` and no link that leaves it). Measured 2026-11-19: `ditto -x -k` already writes `../x` and `/abs/x` inside the
// destination and refuses to write through a symlink, but keeps symlinks that point outside, `.app` itself included.

public enum UpdateArchiveError: Error, Equatable, Sendable {
    /// Not a zip this checker reads (no end record, ZIP64, several disks, a broken header).
    case unreadable
    case tooManyEntries
    case tooLarge
    /// A name that is absolute, has `..` or `.`, an empty part, a backslash or a NUL.
    case unsafePath(String)
    /// The first path part is not the app's folder.
    case unexpectedTopLevel(String)
    /// An entry below an entry that is a symlink (it would be written through the link).
    case throughSymlink(String)
    /// Not a file, a folder or a symlink (a device, a FIFO, a socket).
    case unsupportedEntry(String)
    /// The local header's name is not the central directory's (a zip that reads differently to different tools).
    case nameMismatch(String)
    /// After unpacking: the `.app` is missing, is a symlink, or something else sits next to it.
    case unexpectedLayout(String)
    /// After unpacking: a symlink is absolute or points outside the `.app`.
    case symlinkOutside(String)
}

/// Bounds on what an update may weigh. The universal app is about 60 MB zipped and under 200 MB unpacked, in under
/// 100 entries; the limits leave room to grow while keeping a hostile zip from filling the disk.
public struct UpdateArchiveLimits: Equatable, Sendable {
    public var maxDownloadBytes: Int64 = 512 << 20
    public var maxUnpackedBytes: Int64 = 2 << 30
    public var maxEntries = 10_000

    public init() {}
    public init(maxDownloadBytes: Int64, maxUnpackedBytes: Int64, maxEntries: Int) {
        self.maxDownloadBytes = maxDownloadBytes
        self.maxUnpackedBytes = maxUnpackedBytes
        self.maxEntries = maxEntries
    }
}

/// One entry of a zip's central directory.
public struct ZipEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case file, directory, symlink, other }
    public var name: String
    public var kind: Kind
    public var uncompressedSize: Int64
}

public enum UpdateArchive {
    /// The entries of the zip at `url`, read from its central directory; each local header's name must match.
    public static func entries(of url: URL) throws(UpdateArchiveError) -> [ZipEntry] {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw .unreadable }
        return try entries(in: data)
    }

    static func entries(in data: Data) throws(UpdateArchiveError) -> [ZipEntry] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) throws(UpdateArchiveError) -> Int {
            guard o >= 0, o + 2 <= bytes.count else { throw .unreadable }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) throws(UpdateArchiveError) -> Int {
            guard o >= 0, o + 4 <= bytes.count else { throw .unreadable }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        // End of central directory: the last 0x06054b50 within the final 64 KiB + 22 bytes.
        guard bytes.count >= 22 else { throw .unreadable }
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw .unreadable }
        let disk = try u16(eocd + 4), cdDisk = try u16(eocd + 6)
        let countHere = try u16(eocd + 8), count = try u16(eocd + 10)
        let cdSize = try u32(eocd + 12), cdOffset = try u32(eocd + 16)
        guard disk == 0, cdDisk == 0, countHere == count, count != 0xFFFF, cdSize != 0xFFFF_FFFF,
              cdOffset != 0xFFFF_FFFF, cdOffset + cdSize <= eocd else { throw .unreadable }

        var out: [ZipEntry] = []
        out.reserveCapacity(count)
        var p = cdOffset
        for _ in 0..<count {
            guard try u32(p) == 0x0201_4b50 else { throw .unreadable }
            let madeBy = try u16(p + 4) >> 8
            let compressed = try u32(p + 20), size = try u32(p + 24)
            let nameLength = try u16(p + 28), extraLength = try u16(p + 30), commentLength = try u16(p + 32)
            let external = try u32(p + 38), localOffset = try u32(p + 42)
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF,
                  p + 46 + nameLength <= bytes.count else { throw .unreadable }
            let nameBytes = Array(bytes[(p + 46)..<(p + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw .unsafePath("(not UTF-8)") }

            // The local header the extractor reads must carry the same name.
            guard try u32(localOffset) == 0x0403_4b50 else { throw .unreadable }
            let localNameLength = try u16(localOffset + 26)
            guard localOffset + 30 + localNameLength <= bytes.count,
                  Array(bytes[(localOffset + 30)..<(localOffset + 30 + localNameLength)]) == nameBytes else {
                throw .nameMismatch(name)
            }

            let kind: ZipEntry.Kind
            if madeBy == 3, external >> 16 != 0 {
                switch (external >> 16) & 0o170000 {
                case 0o100000: kind = .file
                case 0o040000: kind = .directory
                case 0o120000: kind = .symlink
                default: kind = .other
                }
            } else {
                kind = name.hasSuffix("/") ? .directory : .file
            }
            out.append(ZipEntry(name: name, kind: kind, uncompressedSize: Int64(size)))
            p += 46 + nameLength + extraLength + commentLength
        }
        return out
    }

    /// Refuses a zip whose entries could land outside `<unpack>/<appName>`, are not plain files, folders or links,
    /// or are too many or too large.
    public static func check(_ entries: [ZipEntry], appName: String, limits: UpdateArchiveLimits = .init())
        throws(UpdateArchiveError) {
        guard entries.count <= limits.maxEntries else { throw .tooManyEntries }
        var total: Int64 = 0
        var links = Set<String>()
        for entry in entries {
            let name = entry.name
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else {
                throw .unsafePath(name)
            }
            var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if entry.kind == .directory, parts.last == "" { parts.removeLast() }
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw .unsafePath(name)
            }
            guard parts[0] == appName else { throw .unexpectedTopLevel(name) }
            guard entry.kind != .other else { throw .unsupportedEntry(name) }
            for k in 1..<parts.count where links.contains(parts[0..<k].joined(separator: "/")) {
                throw .throughSymlink(name)
            }
            if entry.kind == .symlink { links.insert(parts.joined(separator: "/")) }
            total += entry.uncompressedSize
            guard total <= limits.maxUnpackedBytes else { throw .tooLarge }
        }
    }

    /// After unpacking into the empty folder `directory`: it holds exactly the real folder `appName`, every item in
    /// it is a file, a folder or a relative symlink that stays inside it, and the total size is within the limit.
    /// Returns the `.app`.
    @discardableResult
    public static func checkUnpacked(_ directory: URL, appName: String, limits: UpdateArchiveLimits = .init())
        throws(UpdateArchiveError) -> URL {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        guard top == [appName] else { throw .unexpectedLayout(top.sorted().joined(separator: ", ")) }
        let app = directory.appending(path: appName, directoryHint: .isDirectory)
        guard kind(of: app.path) == .directory else { throw .unexpectedLayout(appName) }
        guard let root = realPath(app.path) else { throw .unexpectedLayout(appName) }

        var total: Int64 = 0
        var count = 0
        guard let walker = fm.enumerator(atPath: app.path) else { throw .unexpectedLayout(appName) }
        while let relative = walker.nextObject() as? String {
            count += 1
            guard count <= limits.maxEntries else { throw .tooManyEntries }
            let path = app.appending(path: relative).path
            switch kind(of: path) {
            case .directory: break
            case .file:
                total += (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                guard total <= limits.maxUnpackedBytes else { throw .tooLarge }
            case .symlink:
                guard let target = try? fm.destinationOfSymbolicLink(atPath: path), !target.hasPrefix("/") else {
                    throw .symlinkOutside(relative)
                }
                // Resolved on disk, so a chain of links (`a -> ../..`, `b -> a/../x`) is followed the way the
                // system will follow it. A link that resolves to nothing is refused too.
                guard let resolved = realPath(path), resolved == root || resolved.hasPrefix(root + "/") else {
                    throw .symlinkOutside(relative)
                }
            case .other:
                throw .unsupportedEntry(relative)
            }
        }
        return app
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func kind(of path: String) -> ZipEntry.Kind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .other }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }
}
