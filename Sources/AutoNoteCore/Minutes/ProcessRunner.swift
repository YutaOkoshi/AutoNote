import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ProcessRunning: Sendable {
    /// `environment` replaces the child's environment (callers pass e.g. `ClaudeLocator.childEnvironment`).
    func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
             environment: [String: String], timeout: Duration) async throws -> ProcessResult
}

/// Runs a child process with Foundation `Process`.
/// stdin is written on its own queue while stdout/stderr are drained concurrently, so large payloads do not deadlock.
/// On timeout the child gets SIGTERM, then SIGKILL if still alive after 5 s, and the result has `timedOut = true`.
/// On cancellation of the calling Task the child is stopped the same way and `CancellationError` is thrown.
public struct FoundationProcessRunner: ProcessRunning {
    static let killGrace: Duration = .seconds(5)
    /// After a stopped child exits, how long to keep waiting for EOF from grandchildren still holding the pipes.
    static let drainGrace: Duration = .seconds(1)

    public init() {}

    public func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
                    environment: [String: String], timeout: Duration) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let run = ProcessRunState(process: process)
        process.terminationHandler = { _ in run.markExited() }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; run.markEOF(.stdout) } else { run.append(chunk, to: .stdout) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; run.markEOF(.stderr) } else { run.append(chunk, to: .stderr) }
        }

        return try await withTaskCancellationHandler {
            do {
                try run.launch()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw error
            }
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                // Without this a child that exits before reading all of stdin would SIGPIPE the whole app.
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
            let timer = Task {
                try await Task.sleep(for: timeout)
                run.stop(reason: .timedOut)
            }
            let outcome = await run.completion()
            timer.cancel()
            if outcome.cancelled { throw CancellationError() }
            // A cancel after the timeout already stopped the child is a no-op in `stop`; honour it here.
            try Task.checkCancellation()
            return ProcessResult(exitCode: process.terminationStatus, stdout: outcome.stdout, stderr: outcome.stderr,
                                 timedOut: outcome.timedOut)
        } onCancel: {
            run.stop(reason: .cancelled)
        }
    }
}

private enum ProcessStream { case stdout, stderr }
private enum ProcessStopReason { case timedOut, cancelled }

private struct ProcessOutcome: Sendable {
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    var cancelled: Bool
}

/// Shared, lock-protected state of one child process run.
private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var launched = false
    private var exited = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var drainExpired = false
    private var stopReason: ProcessStopReason?
    private var stdout = Data()
    private var stderr = Data()
    private var finished = false
    private var waiter: CheckedContinuation<ProcessOutcome, Never>?

    init(process: Process) { self.process = process }

    /// Launches unless a stop was already requested (cancellation before launch).
    func launch() throws {
        try lock.withLock {
            if stopReason == .cancelled { throw CancellationError() }
            try process.run()
            launched = true
        }
    }

    func append(_ chunk: Data, to stream: ProcessStream) {
        lock.withLock {
            switch stream {
            case .stdout: stdout.append(chunk)
            case .stderr: stderr.append(chunk)
            }
        }
    }

    func markEOF(_ stream: ProcessStream) {
        finishIfReady {
            switch stream {
            case .stdout: stdoutEOF = true
            case .stderr: stderrEOF = true
            }
        }
    }

    func markExited() {
        let stopped = lock.withLock { exited = true; return stopReason != nil }
        if stopped { scheduleDrainExpiry() }
        finishIfReady {}
    }

    func stop(reason: ProcessStopReason) {
        let action: (pid: pid_t, exitedAlready: Bool)? = lock.withLock {
            guard stopReason == nil, !finished else { return nil }
            stopReason = reason
            guard launched else { return nil }
            return (process.processIdentifier, exited)
        }
        guard let action else { return }
        if action.exitedAlready { scheduleDrainExpiry(); return }
        kill(action.pid, SIGTERM)
        let grace = FoundationProcessRunner.killGrace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace.timeInterval) { [self] in
            let alive = lock.withLock { !exited }
            if alive { kill(action.pid, SIGKILL) }
        }
    }

    func completion() async -> ProcessOutcome {
        await withCheckedContinuation { continuation in
            let ready: ProcessOutcome? = lock.withLock {
                if finished { return outcome() }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func scheduleDrainExpiry() {
        let grace = FoundationProcessRunner.drainGrace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace.timeInterval) { [self] in
            finishIfReady { drainExpired = true }
        }
    }

    /// Applies `change` under the lock and resumes the waiter once the child exited and both pipes are drained.
    private func finishIfReady(_ change: () -> Void) {
        let resume: (CheckedContinuation<ProcessOutcome, Never>?, ProcessOutcome)? = lock.withLock {
            change()
            guard !finished, exited, (stdoutEOF && stderrEOF) || drainExpired else { return nil }
            finished = true
            let w = waiter
            waiter = nil
            return (w, outcome())
        }
        if let (waiter, outcome) = resume { waiter?.resume(returning: outcome) }
    }

    private func outcome() -> ProcessOutcome {
        ProcessOutcome(stdout: stdout, stderr: stderr, timedOut: stopReason == .timedOut, cancelled: stopReason == .cancelled)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
