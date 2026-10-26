import Darwin
import Foundation

/// Thin wrappers over the BSD socket calls used by `SocketServer` and `SocketClient`.
enum UnixSocket {
    /// `sun_path` on Darwin, including the terminating NUL.
    static let maxPathBytes = 104

    static func address(for path: String) throws(SocketError) -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count < maxPathBytes else { throw .pathTooLong(bytes: bytes.count) }
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Every socket fd gets `SO_NOSIGPIPE` (ruling X5: no process-wide SIGPIPE handler) and close-on-exec,
    /// so automations spawned by the app never inherit the listener.
    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func makeSocket() throws(SocketError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system(call: "socket", errno: errno) }
        configure(fd)
        return fd
    }

    /// Connected fd, or the `errno` of the failed `socket`/`connect`.
    static func connect(_ address: sockaddr_un) -> Result<Int32, SocketError> {
        let fd: Int32
        do { fd = try makeSocket() } catch { return .failure(error) }
        var addr = address
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            close(fd)
            return .failure(.system(call: "connect", errno: code))
        }
        return .success(fd)
    }

    /// `socket` → `bind` → `chmod 0600` → `listen(16)`.
    static func listen(_ address: sockaddr_un, path: String) throws(SocketError) -> Int32 {
        let fd = try makeSocket()
        var addr = address
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw fail(fd, "bind") }
        guard chmod(path, 0o600) == 0 else {
            let error = fail(fd, "chmod")
            unlink(path)
            throw error
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let error = fail(fd, "listen")
            unlink(path)
            throw error
        }
        return fd
    }

    private static func fail(_ fd: Int32, _ call: String) -> SocketError {
        let code = errno
        close(fd)
        return .system(call: call, errno: code)
    }

    /// Full-write loop (`write` may be partial). False when the peer is gone.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    /// One blocking `read`; nil on EOF or error.
    static func readSome(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { return Data(buffer[0..<n]) }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// Waits until `fd` is readable. False on timeout.
    static func waitReadable(_ fd: Int32, until deadline: ContinuousClock.Instant) -> Bool {
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return false }
            let c = remaining.components
            let ms = Int32(clamping: c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000 + 1)
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&p, 1, ms)
            if rc > 0 { return true }
            if rc < 0 && errno != EINTR { return true }  // let the read report the error
        }
    }
}
