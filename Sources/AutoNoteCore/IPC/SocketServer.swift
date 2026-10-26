import Darwin
import Foundation
import Synchronization

/// Answers one decoded request; the server writes the response back as one JSON line.
public protocol IPCHandler: Sendable {
    func handle(_ request: IPCRequest) async -> IPCResponse
}

public enum SocketError: Error, Equatable, Sendable {
    case pathTooLong(bytes: Int)
    case alreadyRunning
    case system(call: String, errno: Int32)
}

/// UNIX-socket JSON-lines server: one blocking accept thread, one thread per connection.
public actor SocketServer {
    private let socketURL: URL
    private let handler: any IPCHandler
    private var listener: Listener?

    public init(socketURL: URL, handler: any IPCHandler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws(SocketError) {
        guard listener == nil else { return }
        let path = socketURL.path
        let address = try UnixSocket.address(for: path)
        try makeParentFolder()
        var st = stat()
        if lstat(path, &st) == 0 {
            // A live server answers `connect`; never unlink its socket. Anything else is stale.
            if case .success(let fd) = UnixSocket.connect(address) {
                close(fd)
                throw .alreadyRunning
            }
            guard unlink(path) == 0 else { throw .system(call: "unlink", errno: errno) }
        }
        let fd = try UnixSocket.listen(address, path: path)
        let listener: Listener
        do {
            listener = try Listener(fd: fd, handler: handler)
        } catch {
            close(fd)
            unlink(path)
            throw error
        }
        listener.run()
        self.listener = listener
    }

    public func stop() {
        guard let listener else { return }
        listener.stop()
        self.listener = nil
        unlink(socketURL.path)
    }

    private func makeParentFolder() throws(SocketError) {
        let folder = socketURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw .system(call: "mkdir", errno: Int32(underlying?.code ?? Int(EIO)))
        }
    }
}

/// Owns the listening fd and the live connections. `stop()` wakes the accept thread through a pipe
/// and shuts the connections down; each thread closes its own fds, so fd numbers are never reused under it.
private final class Listener: Sendable {
    private struct State {
        var stopped = false
        var connections: Set<Int32> = []
    }

    private let fd: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let handler: any IPCHandler
    private let state = Mutex(State())

    init(fd: Int32, handler: any IPCHandler) throws(SocketError) {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw .system(call: "pipe", errno: errno) }
        for p in pipeFDs { _ = fcntl(p, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(pipeFDs[1], F_SETNOSIGPIPE, 1)
        self.fd = fd
        self.wakeRead = pipeFDs[0]
        self.wakeWrite = pipeFDs[1]
        self.handler = handler
    }

    func run() {
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "AutoNote IPC accept"
        thread.start()
    }

    func stop() {
        let connections = state.withLock { s -> Set<Int32> in
            s.stopped = true
            return s.connections
        }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
        for c in connections { shutdown(c, SHUT_RDWR) }
    }

    private func acceptLoop() {
        defer {
            close(fd)
            close(wakeRead)
            close(wakeWrite)
        }
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let rc = poll(&fds, 2, -1)
            if rc < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 || state.withLock({ $0.stopped }) { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
                return
            }
            UnixSocket.configure(c)
            let registered = state.withLock { s -> Bool in
                guard !s.stopped else { return false }
                s.connections.insert(c)
                return true
            }
            guard registered else {
                close(c)
                return
            }
            let thread = Thread { [self] in
                serve(c)
                state.withLock { _ = $0.connections.remove(c) }
                close(c)
            }
            thread.name = "AutoNote IPC connection"
            thread.start()
        }
    }

    /// Reads lines and answers each in order. A complete line that fails to decode gets a failure
    /// response and the connection stays open; an overlong line gets one failure and the connection closes
    /// (the buffered tail of that line is unusable).
    private func serve(_ c: Int32) {
        var buffer = LineBuffer()
        while let chunk = UnixSocket.readSome(c) {
            let lines: [Data]
            do {
                lines = try buffer.append(chunk)
            } catch {
                _ = reply(c, .failure(nil, error))
                return
            }
            for line in lines {
                let response: IPCResponse
                do {
                    response = handle(try IPCCodec.decodeRequest(line))
                } catch {
                    response = .failure(error.id, error.error)
                }
                guard reply(c, response) else { return }
            }
        }
    }

    /// Bridges the async handler onto this dedicated connection thread.
    private func handle(_ request: IPCRequest) -> IPCResponse {
        let box = Mutex<IPCResponse?>(nil)
        let done = DispatchSemaphore(value: 0)
        let handler = handler
        Task {
            let response = await handler.handle(request)
            box.withLock { $0 = response }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 } ?? .failure(request.id, IPCError(code: .failed, message: "応答がありません"))
    }

    private func reply(_ c: Int32, _ response: IPCResponse) -> Bool {
        let fallback = IPCResponse.failure(response.id, IPCError(code: .failed, message: "応答を書き出せません"))
        guard let data = (try? IPCCodec.encode(response)) ?? (try? IPCCodec.encode(fallback)) else { return false }
        return UnixSocket.writeAll(c, data)
    }
}
