import Foundation
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

/// A stored (uncompressed) zip written by hand, so the tests can build entries no well-behaved tool would write:
/// `../` names, absolute names, a file below a symlink, a local header whose name differs from the directory's.
struct TestZip {
    struct Entry {
        var name: String
        var data = Data()
        var mode: UInt32 = 0o100644
        var localName: String? = nil
    }
    var entries: [Entry] = []

    mutating func file(_ name: String, _ text: String = "x") { entries.append(Entry(name: name, data: Data(text.utf8))) }
    mutating func dir(_ name: String) { entries.append(Entry(name: name.hasSuffix("/") ? name : name + "/", mode: 0o040755)) }
    mutating func link(_ name: String, to target: String) {
        entries.append(Entry(name: name, data: Data(target.utf8), mode: 0o120755))
    }

    var data: Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
        func u32(_ v: UInt32, _ d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        for e in entries {
            let offset = UInt32(out.count)
            let name = Data(e.name.utf8), local = Data((e.localName ?? e.name).utf8)
            let crc = Self.crc32(e.data)
            u32(0x0403_4b50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(e.data.count), &out); u32(UInt32(e.data.count), &out)
            u16(local.count, &out); u16(0, &out); out.append(local); out.append(e.data)
            u32(0x0201_4b50, &central); u16(3 << 8 | 20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0x21, &central); u32(crc, &central); u32(UInt32(e.data.count), &central)
            u32(UInt32(e.data.count), &central); u16(name.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(e.mode << 16, &central); u32(offset, &central); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// A minimal app tree with the framework-style relative links a real bundle has.
    static func goodApp() -> TestZip {
        var z = TestZip()
        z.dir("AutoNote.app"); z.dir("AutoNote.app/Contents")
        z.file("AutoNote.app/Contents/Info.plist", "<plist/>")
        z.dir("AutoNote.app/Contents/Frameworks/w.framework/Versions/A")
        z.file("AutoNote.app/Contents/Frameworks/w.framework/Versions/A/w", "bin")
        z.link("AutoNote.app/Contents/Frameworks/w.framework/Versions/Current", to: "A")
        z.link("AutoNote.app/Contents/Frameworks/w.framework/w", to: "Versions/Current/w")
        return z
    }
}

@Suite struct UpdateArchiveZipTests {
    func check(_ z: TestZip, limits: UpdateArchiveLimits = .init()) throws(UpdateArchiveError) {
        try UpdateArchive.check(UpdateArchive.entries(in: z.data), appName: "AutoNote.app", limits: limits)
    }

    @Test func readsTheDirectoryOfAGoodApp() throws {
        let entries = try UpdateArchive.entries(in: TestZip.goodApp().data)
        #expect(entries.count == 7)
        #expect(entries.first { $0.name.hasSuffix("Current") }?.kind == .symlink)
        #expect(entries.first { $0.name == "AutoNote.app/" }?.kind == .directory)
        try check(TestZip.goodApp())
    }

    @Test func refusesNamesThatLeaveTheFolder() {
        for name in ["../../escape.txt", "AutoNote.app/../../escape.txt", "/tmp/escape.txt", "AutoNote.app/./x",
                     "AutoNote.app//x", #"AutoNote.app\..\x"#] {
            var z = TestZip.goodApp()
            z.file(name)
            #expect(throws: UpdateArchiveError.unsafePath(name), "\(name)") { try check(z) }
        }
    }

    @Test func refusesSomethingBesideTheApp() {
        var z = TestZip.goodApp()
        z.file("Other.app/Contents/Info.plist")
        #expect(throws: UpdateArchiveError.unexpectedTopLevel("Other.app/Contents/Info.plist")) { try check(z) }
        var z2 = TestZip.goodApp()
        z2.file("__MACOSX/x")
        #expect(throws: UpdateArchiveError.unexpectedTopLevel("__MACOSX/x")) { try check(z2) }
    }

    @Test func refusesAFileBelowASymlink() {
        var z = TestZip.goodApp()
        z.link("AutoNote.app/Contents/out", to: "/Users/someone/Library/LaunchAgents")
        z.file("AutoNote.app/Contents/out/x.plist")
        #expect(throws: UpdateArchiveError.throughSymlink("AutoNote.app/Contents/out/x.plist")) { try check(z) }
    }

    @Test func refusesDevicesAndFIFOs() {
        var z = TestZip.goodApp()
        z.entries.append(.init(name: "AutoNote.app/Contents/fifo", mode: 0o010644))
        #expect(throws: UpdateArchiveError.unsupportedEntry("AutoNote.app/Contents/fifo")) { try check(z) }
    }

    @Test func refusesTooManyOrTooLarge() {
        let few = UpdateArchiveLimits(maxDownloadBytes: 1 << 20, maxUnpackedBytes: 1 << 20, maxEntries: 3)
        #expect(throws: UpdateArchiveError.tooManyEntries) { try check(TestZip.goodApp(), limits: few) }
        var z = TestZip.goodApp()
        z.file("AutoNote.app/Contents/big", String(repeating: "a", count: 2_000))
        let small = UpdateArchiveLimits(maxDownloadBytes: 1 << 20, maxUnpackedBytes: 1_000, maxEntries: 100)
        #expect(throws: UpdateArchiveError.tooLarge) { try check(z, limits: small) }
    }

    @Test func refusesALocalHeaderThatDisagrees() {
        var z = TestZip.goodApp()
        z.entries.append(.init(name: "AutoNote.app/Contents/ok", data: Data("x".utf8), localName: "../../evil"))
        #expect(throws: UpdateArchiveError.nameMismatch("AutoNote.app/Contents/ok")) { try check(z) }
    }

    @Test func refusesWhatIsNotAZip() {
        #expect(throws: UpdateArchiveError.unreadable) { try UpdateArchive.entries(in: Data("pretend zip".utf8)) }
        #expect(throws: UpdateArchiveError.unreadable) { try UpdateArchive.entries(in: Data()) }
    }
}

/// The real `ditto` behind the checks: a good zip unpacks, a hostile one is refused before anything is written.
@Suite struct UpdateArchiveDittoTests {
    @Test func unpacksAGoodAppWithItsLinks() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appending(path: "a.zip")
        try TestZip.goodApp().data.write(to: zip)
        let out = dir.appending(path: "unpacked")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await DittoExtractor().extract(zip, into: out)
        let app = try UpdateArchive.checkUnpacked(out, appName: "AutoNote.app")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: app.appending(path: "Contents/Frameworks/w.framework/Versions/Current").path) == "A")
    }

    @Test func hostileZipsWriteNothing() async throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var dotdot = TestZip.goodApp(); dotdot.file("../../outside/dotdot.txt")
        var through = TestZip.goodApp()
        through.link("AutoNote.app/Contents/out", to: outside.path); through.file("AutoNote.app/Contents/out/through.txt")
        var absolute = TestZip.goodApp(); absolute.file(outside.appending(path: "abs.txt").path)
        for (i, z) in [dotdot, through, absolute].enumerated() {
            let zip = dir.appending(path: "\(i).zip")
            try z.data.write(to: zip)
            let out = dir.appending(path: "u\(i)/a/b")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            await #expect(throws: UpdateArchiveError.self) { try await DittoExtractor().extract(zip, into: out) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}

@Suite struct UpdateArchiveUnpackedTests {
    func tree(_ build: (URL) throws -> Void) throws -> (URL, URL) {
        let dir = try TemporaryDirectory.make()
        let unpacked = dir.appending(path: "unpacked")
        try FileManager.default.createDirectory(at: unpacked.appending(path: "AutoNote.app/Contents/Frameworks/w.framework/Versions/A"),
                                                withIntermediateDirectories: true)
        try build(unpacked.appending(path: "AutoNote.app"))
        return (dir, unpacked)
    }

    @Test func acceptsLinksThatStayInside() throws {
        let (dir, unpacked) = try tree { app in
            try FileManager.default.createSymbolicLink(atPath: app.appending(path: "Contents/Frameworks/w.framework/Versions/Current").path,
                                                       withDestinationPath: "A")
            // A link to a folder above it, still inside: the walk must not follow it (no endless loop).
            try FileManager.default.createSymbolicLink(atPath: app.appending(path: "Contents/loop").path, withDestinationPath: "..")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try UpdateArchive.checkUnpacked(unpacked, appName: "AutoNote.app").lastPathComponent == "AutoNote.app")
    }

    @Test func refusesLinksThatLeave() throws {
        for target in ["/Users/someone", "../../..", "../../../outside", "Frameworks/../../../x", "missing"] {
            let (dir, unpacked) = try tree { app in
                try FileManager.default.createSymbolicLink(atPath: app.appending(path: "Contents/l").path, withDestinationPath: target)
            }
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(throws: UpdateArchiveError.symlinkOutside("Contents/l"), "\(target)") {
                try UpdateArchive.checkUnpacked(unpacked, appName: "AutoNote.app")
            }
        }
    }

    @Test func followsAChainOfLinksTheWayTheSystemDoes() throws {
        // Each link looks inside on its own (`b` → `deep/a/../x` reads as `Contents/deep/x`), but `a` is `../..`,
        // so `b` really resolves above the app.
        let (dir, unpacked) = try tree { app in
            let fm = FileManager.default
            try fm.createDirectory(at: app.appending(path: "Contents/deep"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: app.appending(path: "Contents/deep/a").path, withDestinationPath: "../..")
            try fm.createSymbolicLink(atPath: app.appending(path: "Contents/b").path, withDestinationPath: "deep/a/..")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: UpdateArchiveError.symlinkOutside("Contents/b")) {
            try UpdateArchive.checkUnpacked(unpacked, appName: "AutoNote.app")
        }
    }

    @Test func refusesAnAppThatIsALinkOrHasCompany() throws {
        let dir = try TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let real = dir.appending(path: "elsewhere/AutoNote.app")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let linked = dir.appending(path: "u1")
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linked.appending(path: "AutoNote.app"), withDestinationURL: real)
        #expect(throws: UpdateArchiveError.unexpectedLayout("AutoNote.app")) {
            try UpdateArchive.checkUnpacked(linked, appName: "AutoNote.app")
        }
        let crowded = dir.appending(path: "u2")
        try fm.createDirectory(at: crowded.appending(path: "AutoNote.app"), withIntermediateDirectories: true)
        try Data().write(to: crowded.appending(path: ".hidden"))
        #expect(throws: UpdateArchiveError.unexpectedLayout(".hidden, AutoNote.app")) {
            try UpdateArchive.checkUnpacked(crowded, appName: "AutoNote.app")
        }
        let fifo = dir.appending(path: "u3")
        try fm.createDirectory(at: fifo.appending(path: "AutoNote.app"), withIntermediateDirectories: true)
        #expect(mkfifo(fifo.appending(path: "AutoNote.app/p").path, 0o644) == 0)
        #expect(throws: UpdateArchiveError.unsupportedEntry("p")) { try UpdateArchive.checkUnpacked(fifo, appName: "AutoNote.app") }
    }
}
