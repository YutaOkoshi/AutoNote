import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct ProcessRunnerTests {
    private let sh = URL(fileURLWithPath: "/bin/sh")
    private let env = ProcessInfo.processInfo.environment

    @Test func passesArgumentsStdinAndCwd() async throws {
        let cwd = try TemporaryDirectory.make()
        let result = try await FoundationProcessRunner().run(
            executable: sh,
            arguments: ["-c", "printf \"%s|\" \"$@\"; pwd; cat", "sh", "a", "", "b c"],
            stdin: Data("入力".utf8), workingDirectory: cwd, environment: env, timeout: .seconds(10))
        // realpath, not resolvingSymlinksInPath: the latter maps /private/var back to /var.
        let real = try #require(realpath(cwd.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        #expect(result.exitCode == 0)
        #expect(result.timedOut == false)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "a||b c|\(real)\n入力")
    }

    @Test func environmentReplacesParentEnvironment() async throws {
        let result = try await FoundationProcessRunner().run(
            executable: sh, arguments: ["-c", "printf '%s' \"$AUTONOTE_TEST_VAR:${HOME-unset}\""],
            stdin: Data(), workingDirectory: try TemporaryDirectory.make(),
            environment: ["AUTONOTE_TEST_VAR": "v1"], timeout: .seconds(10))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "v1:unset")
    }

    @Test func nonZeroExitCodeAndStderrAreReported() async throws {
        let result = try await FoundationProcessRunner().run(
            executable: sh, arguments: ["-c", "printf err >&2; exit 3"],
            stdin: Data(), workingDirectory: try TemporaryDirectory.make(), environment: env, timeout: .seconds(10))
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err")
        #expect(result.stdout.isEmpty)
    }

    @Test func largeStdinDoesNotDeadlock() async throws {
        let input = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        let start = ContinuousClock.now
        let result = try await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: input,
            workingDirectory: try TemporaryDirectory.make(), environment: env, timeout: .seconds(10))
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(result.timedOut == false)
        #expect(result.stdout.count == 300_000)
        #expect(result.stdout == input)
    }

    @Test func largeStdoutAndStderrAreBothRead() async throws {
        let script = "head -c 200000 /dev/zero | tr '\\0' o; head -c 200000 /dev/zero | tr '\\0' e >&2"
        let result = try await FoundationProcessRunner().run(
            executable: sh, arguments: ["-c", script], stdin: Data(),
            workingDirectory: try TemporaryDirectory.make(), environment: env, timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr.count == 200_000)
        #expect(result.stdout.allSatisfy { $0 == UInt8(ascii: "o") })
        #expect(result.stderr.allSatisfy { $0 == UInt8(ascii: "e") })
    }

    @Test func timeoutKillsProcess() async throws {
        let dir = try TemporaryDirectory.make()
        let pidFile = dir.appending(path: "pid")
        let start = ContinuousClock.now
        let result = try await FoundationProcessRunner().run(
            executable: sh, arguments: ["-c", "echo $$ > \"$0\"; exec sleep 30", pidFile.path], stdin: Data(),
            workingDirectory: dir, environment: env, timeout: .seconds(1))
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(result.timedOut == true)
        let pid = try #require(pid_t(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }

    @Test func timeoutEscalatesToSigkillWhenSigtermIsIgnored() async throws {
        let dir = try TemporaryDirectory.make()
        let pidFile = dir.appending(path: "pid")
        let start = ContinuousClock.now
        let result = try await FoundationProcessRunner().run(
            executable: sh,
            arguments: ["-c", "trap '' TERM; echo $$ > \"$0\"; while :; do sleep 1; done", pidFile.path],
            stdin: Data(), workingDirectory: dir, environment: env, timeout: .seconds(1))
        let elapsed = ContinuousClock.now - start
        #expect(result.timedOut == true)
        #expect(elapsed >= .seconds(5))
        #expect(elapsed < .seconds(10))
        let pid = try #require(pid_t(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }

    @Test func cancellationTerminatesProcess() async throws {
        let dir = try TemporaryDirectory.make()
        let pidFile = dir.appending(path: "pid")
        let env = self.env
        let sh = self.sh
        let task = Task {
            try await FoundationProcessRunner().run(
                executable: sh, arguments: ["-c", "echo $$ > \"$0\"; exec sleep 30", pidFile.path], stdin: Data(),
                workingDirectory: dir, environment: env, timeout: .seconds(60))
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: pidFile.path) || (try? Data(contentsOf: pidFile))?.isEmpty != false {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(pid_t(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(kill(pid, 0) != 0)
    }

    @Test func cancellationAfterTimeoutStillThrowsCancellationError() async throws {
        // The child ignores SIGTERM, so after the timeout fires it lives on until SIGKILL (5 s);
        // cancelling inside that window must still surface as CancellationError, not a timed-out result.
        let env = self.env
        let sh = self.sh
        let task = Task {
            try await FoundationProcessRunner().run(
                executable: sh, arguments: ["-c", "trap '' TERM; exec sleep 30"], stdin: Data(),
                workingDirectory: try TemporaryDirectory.make(), environment: env, timeout: .milliseconds(200))
        }
        try await Task.sleep(for: .seconds(1))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func alreadyCancelledTaskDoesNotLaunch() async throws {
        let dir = try TemporaryDirectory.make()
        let marker = dir.appending(path: "ran")
        let env = self.env
        let sh = self.sh
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FoundationProcessRunner().run(
                executable: sh, arguments: ["-c", "touch \"$0\"", marker.path], stdin: Data(),
                workingDirectory: dir, environment: env, timeout: .seconds(10))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func missingExecutableThrows() async throws {
        await #expect(throws: (any Error).self) {
            try await FoundationProcessRunner().run(
                executable: URL(fileURLWithPath: "/nonexistent/autonote-no-such-binary"), arguments: [], stdin: Data(),
                workingDirectory: try TemporaryDirectory.make(), environment: [:], timeout: .seconds(5))
        }
    }
}
