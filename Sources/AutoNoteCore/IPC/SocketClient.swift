import Darwin
import Foundation
import Synchronization

/// Starts the app when the CLI finds no socket.
public protocol AppLauncher: Sendable {
    func launch() throws
}

/// Runs `/usr/bin/open -g -b <bundleID>` (`-g`: stay in the background).
public struct OpenBundleLauncher: AppLauncher {
    public let bundleID: String

    public init(bundleID: String = AppIdentity.bundleID) {
        self.bundleID = bundleID
    }

    public func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", bundleID]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenBundleLaunchFailure(bundleID: bundleID, status: process.terminationStatus,
                                          stderr: String(decoding: output, as: UTF8.self))
        }
    }
}

struct OpenBundleLaunchFailure: Error, CustomStringConvertible {
    var bundleID: String
    var status: Int32
    var stderr: String

    var description: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "open -g -b \(bundleID) が終了コード \(status) で失敗しました" + (detail.isEmpty ? "" : ": \(detail)")
    }
}

public enum SocketClientError: Error, Equatable, Sendable {
    case appNotRunning
    case launchFailed(String)
    case timedOut
    case protocolError(String)
}

/// One request per connection: connect (launching the app if needed), write one line, read one line.
public struct SocketClient: Sendable {
    private let socketURL: URL
    private let launcher: (any AppLauncher)?
    private let launchTimeout: Duration
    private let pollInterval: Duration
    private let ids = RequestIDs()

    public init(socketURL: URL, launcher: (any AppLauncher)?, launchTimeout: Duration = .seconds(10),
                pollInterval: Duration = .milliseconds(200)) {
        self.socketURL = socketURL
        self.launcher = launcher
        self.launchTimeout = launchTimeout
        self.pollInterval = pollInterval
    }

    /// `launchTimeout` bounds launch + connect; `responseTimeout` separately bounds waiting for the response line (X18).
    public func send(_ cmd: IPCCommand, args: IPCArgs,
                     responseTimeout: Duration = .seconds(10)) async throws(SocketClientError) -> IPCResponse {
        let address: sockaddr_un
        do {
            address = try UnixSocket.address(for: socketURL.path)
        } catch {
            throw .protocolError("ソケットのパスが長すぎます: \(socketURL.path)")
        }
        let fd = try await connect(address)
        defer { close(fd) }

        let id = ids.next()
        let line: Data
        do {
            line = try IPCCodec.encode(IPCRequest(cmd: cmd, args: args, id: id))
        } catch {
            throw .protocolError("要求を書き出せません: \(error)")
        }
        let deadline = ContinuousClock.now + responseTimeout
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Exchange, Never>) in
            let thread = Thread { continuation.resume(returning: Self.exchange(fd, line, until: deadline)) }
            thread.name = "AutoNote IPC client"
            thread.start()
        }
        let reply: Data
        switch outcome {
        case .line(let data): reply = data
        case .timedOut: throw .timedOut
        case .closed: throw .protocolError("応答の前に接続が閉じられました")
        case .failed(let message): throw .protocolError(message)
        }
        let response: IPCResponse
        do {
            response = try IPCCodec.decodeResponse(reply)
        } catch {
            throw .protocolError("応答を読めません")
        }
        if let rid = response.id, rid != id { throw .protocolError("応答の id が違います: \(rid) (要求 \(id))") }
        return response
    }

    private func connect(_ address: sockaddr_un) async throws(SocketClientError) -> Int32 {
        if let fd = try Self.tryConnect(address) { return fd }
        guard let launcher else { throw .appNotRunning }
        do {
            try launcher.launch()
        } catch {
            throw .launchFailed(String(describing: error))
        }
        let deadline = ContinuousClock.now + launchTimeout
        while true {
            if let fd = try Self.tryConnect(address) { return fd }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw .timedOut }
            do {
                try await Task.sleep(for: min(pollInterval, remaining))
            } catch {
                throw .timedOut
            }
        }
    }

    /// nil when no server listens yet (`ENOENT` / `ECONNREFUSED`).
    private static func tryConnect(_ address: sockaddr_un) throws(SocketClientError) -> Int32? {
        switch UnixSocket.connect(address) {
        case .success(let fd):
            return fd
        case .failure(.system(call: "connect", errno: let code)) where code == ENOENT || code == ECONNREFUSED:
            return nil
        case .failure(let error):
            throw .protocolError("接続できません: \(error)")
        }
    }

    private enum Exchange: Sendable {
        case line(Data), timedOut, closed, failed(String)
    }

    private static func exchange(_ fd: Int32, _ request: Data, until deadline: ContinuousClock.Instant) -> Exchange {
        guard UnixSocket.writeAll(fd, request) else { return .closed }
        var buffer = LineBuffer()
        while true {
            guard UnixSocket.waitReadable(fd, until: deadline) else { return .timedOut }
            guard let chunk = UnixSocket.readSome(fd) else { return .closed }
            do {
                if let first = try buffer.append(chunk).first { return .line(first) }
            } catch {
                return .failed(error.message)
            }
        }
    }
}

/// Request ids start at 1 and are shared by copies of one client.
private final class RequestIDs: Sendable {
    private let last = Mutex(0)

    func next() -> Int {
        last.withLock {
            $0 += 1
            return $0
        }
    }
}
