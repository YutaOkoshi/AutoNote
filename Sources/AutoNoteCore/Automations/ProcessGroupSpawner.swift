import Darwin
import Foundation

public struct SpawnError: Error, Equatable, CustomStringConvertible {
    public var call: String
    public var code: Int32
    public init(call: String, code: Int32) { self.call = call; self.code = code }
    public var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
}

/// Starts a child in its own process group (pgid = child pid) so the whole tree can be signalled with `kill(-pid, …)`.
/// stdout / stderr go straight to files (no pipes, so large output never blocks); stdin is fed from a pipe on a
/// separate thread and closed afterwards, with EPIPE ignored when the child does not read it.
public enum ProcessGroupSpawner {
    public static func spawn(arguments: [String], environment: [String: String], stdin: Data,
                             stdoutFile: URL, stderrFile: URL) throws -> pid_t {
        precondition(!arguments.isEmpty, "arguments[0] is the executable path")
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnError(call: "pipe", code: errno) }
        let readFD = fds[0], writeFD = fds[1]
        // Keep both ends out of any concurrent spawn elsewhere in the app (dup2 onto fd 0 clears it in the child).
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        // A child that exits without reading stdin must not SIGPIPE the app.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readFD, STDIN_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdoutFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderrFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // CLOEXEC_DEFAULT: the child gets only fds 0-2. SETSIGDEF/SETSIGMASK: the shell starts with default
        // signal handling even if the app ignores or blocks some signals.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals)
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, arguments[0], &actions, &attr, argv, envp)
        close(readFD)
        guard rc == 0 else {
            close(writeFD)
            throw SpawnError(call: "posix_spawn", code: rc)
        }

        let thread = Thread {
            stdin.withUnsafeBytes { raw in
                guard var p = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let n = write(writeFD, p, left)
                    if n < 0 {
                        if errno == EINTR { continue }
                        break   // EPIPE: the child closed stdin or exited
                    }
                    p += n
                    left -= n
                }
            }
            close(writeFD)
        }
        thread.start()
        return pid
    }

    /// Blocks until `pid` exits and returns its raw wait status. Call off the cooperative pool.
    static func waitBlocking(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return -1 }
        }
        return status
    }
}
