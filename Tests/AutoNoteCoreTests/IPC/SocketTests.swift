import Darwin
import Foundation
import Synchronization
import Testing
@testable import AutoNoteCore

private struct EchoHandler: IPCHandler {
    func handle(_ request: IPCRequest) async -> IPCResponse {
        guard request.cmd == .status else {
            return .failure(request.id, IPCError(code: .unknownCommand, message: "echo only"))
        }
        return .success(request.id, IPCResult(path: "echo-\(request.id)"))
    }
}

private final class FakeLauncher: AppLauncher {
    private let count = Mutex(0)
    private let action: @Sendable () throws -> Void

    init(_ action: @escaping @Sendable () throws -> Void = {}) { self.action = action }

    var launches: Int { count.withLock { $0 } }

    func launch() throws {
        count.withLock { $0 += 1 }
        try action()
    }
}

private struct LaunchBoom: Error {}

/// A fresh `/tmp/an-<8hex>/` folder; the socket lives at `s.sock` inside it.
private struct TempSocket {
    let folder: URL
    var socketURL: URL { folder.appendingPathComponent("s.sock") }

    init() {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        folder = URL(fileURLWithPath: "/tmp/an-\(hex)", isDirectory: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

/// Raw client used to send bytes the real client never would.
private enum RawSocket {
    static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0 ? fd : -1
    }

    static func write(_ fd: Int32, _ s: String) { writeAll(fd, Array(s.utf8)) }

    /// Writes until done or the peer goes away (errors ignored; SO_NOSIGPIPE keeps us alive).
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// Reads up to and including one `\n`; nil on EOF/timeout.
    static func readLine(_ fd: Int32) -> Data? {
        var out = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return out }
            out.append(byte)
        }
        return nil
    }
}

@Suite struct SocketTests {
    private func client(_ t: TempSocket, launcher: (any AppLauncher)? = nil,
                        launchTimeout: Duration = .seconds(10)) -> SocketClient {
        SocketClient(socketURL: t.socketURL, launcher: launcher, launchTimeout: launchTimeout, pollInterval: .milliseconds(50))
    }

    private func clientError(_ c: SocketClient) async -> SocketClientError? {
        do {
            _ = try await c.send(.status, args: IPCArgs())
            return nil
        } catch {
            return error
        }
    }

    @Test func roundTrip() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await server.start()
        let response = try await client(t).send(.status, args: IPCArgs())
        #expect(response.ok)
        #expect(response.id == 1)
        #expect(response.result?.path == "echo-1")
        await server.stop()
    }

    @Test func socketFileIs0600() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await server.start()
        var st = stat()
        #expect(stat(t.socketURL.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
        var dir = stat()
        #expect(stat(t.folder.path, &dir) == 0)
        #expect(dir.st_mode & 0o777 == 0o700)
        await server.stop()
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        try FileManager.default.createDirectory(at: t.folder, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: t.socketURL)
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await server.start()
        let response = try await client(t).send(.status, args: IPCArgs())
        #expect(response.result?.path == "echo-1")
        await server.stop()
    }

    @Test func secondServerFailsAlreadyRunning() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let first = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await first.start()
        let second = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        await #expect(throws: SocketError.alreadyRunning) { try await second.start() }
        #expect(FileManager.default.fileExists(atPath: t.socketURL.path))
        let response = try await client(t).send(.status, args: IPCArgs())
        #expect(response.ok)
        #expect(response.result?.path == "echo-1")
        await first.stop()
    }

    @Test func pathTooLongIsRejected() async {
        let t = TempSocket()
        defer { t.cleanUp() }
        let deep = t.folder.appendingPathComponent(String(repeating: "x", count: 120)).appendingPathComponent("s.sock")
        let server = SocketServer(socketURL: deep, handler: EchoHandler())
        do {
            try await server.start()
            Issue.record("start should have thrown")
        } catch {
            guard case .pathTooLong(let bytes) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(bytes >= 104)
            #expect(bytes == deep.path.utf8.count)
        }
        #expect(!FileManager.default.fileExists(atPath: t.folder.path))
    }

    @Test func concurrentClients() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await server.start()
        let c = client(t)
        let responses = try await withThrowingTaskGroup(of: IPCResponse.self) { group in
            for _ in 0..<5 { group.addTask { try await c.send(.status, args: IPCArgs()) } }
            var all: [IPCResponse] = []
            for try await r in group { all.append(r) }
            return all
        }
        #expect(responses.count == 5)
        for r in responses {
            #expect(r.ok)
            #expect(r.result?.path == "echo-\(r.id ?? -1)")
        }
        #expect(Set(responses.compactMap(\.id)) == Set(1...5))
        await server.stop()
    }

    @Test func badLineGetsBadRequest() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await server.start()
        let fd = RawSocket.connect(t.socketURL.path)
        try #require(fd >= 0)
        defer { close(fd) }
        RawSocket.write(fd, "hello\n")
        let line = try #require(RawSocket.readLine(fd))
        let bad = try IPCCodec.decodeResponse(line)
        #expect(!bad.ok)
        #expect(bad.id == nil)
        #expect(bad.error?.code == .badRequest)
        // The connection stays open: a valid request on the same fd is answered.
        RawSocket.write(fd, #"{"cmd":"status","args":{},"id":42}"# + "\n")
        let next = try IPCCodec.decodeResponse(try #require(RawSocket.readLine(fd)))
        #expect(next.ok)
        #expect(next.result?.path == "echo-42")
        await server.stop()
    }

    @Test func overlongLineClosesConnection() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await server.start()
        let fd = RawSocket.connect(t.socketURL.path)
        try #require(fd >= 0)
        defer { close(fd) }
        RawSocket.writeAll(fd, [UInt8](repeating: 0x61, count: LineBuffer.maxLineBytes + 1))
        let line = try #require(RawSocket.readLine(fd))
        let failure = try IPCCodec.decodeResponse(line)
        #expect(!failure.ok)
        #expect(failure.id == nil)
        #expect(failure.error?.code == .badRequest)
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)
        await server.stop()
    }

    @Test func clientLaunchesAppWhenSocketMissing() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        let launcher = FakeLauncher {
            Task {
                try await Task.sleep(for: .milliseconds(300))
                try await server.start()
            }
        }
        let response = try await client(t, launcher: launcher).send(.status, args: IPCArgs())
        #expect(response.ok)
        #expect(response.result?.path == "echo-1")
        #expect(launcher.launches == 1)
        await server.stop()
    }

    @Test func clientTimesOutWhenAppNeverAppears() async {
        let t = TempSocket()
        defer { t.cleanUp() }
        let launcher = FakeLauncher()
        let started = ContinuousClock.now
        let error = await clientError(client(t, launcher: launcher, launchTimeout: .seconds(1)))
        let elapsed = ContinuousClock.now - started
        #expect(error == .timedOut)
        #expect(elapsed < .seconds(5))
        #expect(elapsed >= .milliseconds(900))
        #expect(launcher.launches == 1)
    }

    @Test func launcherFailureIsReported() async {
        let t = TempSocket()
        defer { t.cleanUp() }
        let launcher = FakeLauncher { throw LaunchBoom() }
        let error = await clientError(client(t, launcher: launcher))
        guard case .launchFailed = error else {
            Issue.record("expected launchFailed, got \(String(describing: error))")
            return
        }
        #expect(launcher.launches == 1)
    }

    @Test func noLauncherFailsFast() async {
        let t = TempSocket()
        defer { t.cleanUp() }
        let started = ContinuousClock.now
        let error = await clientError(client(t, launcher: nil))
        #expect(error == .appNotRunning)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func stopRemovesSocketFile() async throws {
        let t = TempSocket()
        defer { t.cleanUp() }
        let server = SocketServer(socketURL: t.socketURL, handler: EchoHandler())
        try await server.start()
        #expect(FileManager.default.fileExists(atPath: t.socketURL.path))
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: t.socketURL.path))
        #expect(await clientError(client(t)) == .appNotRunning)
    }
}
