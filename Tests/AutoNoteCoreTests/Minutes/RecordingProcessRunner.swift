import Foundation
import Synchronization
@testable import AutoNoteCore

/// A `ProcessRunning` that records every call and never starts a process. `auth …` calls answer `auth`,
/// every other call answers `responses[n]` (the last one once they run out).
final class RecordingProcessRunner: ProcessRunning {
    struct Call: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private let calls = Mutex<[Call]>([])
    private let auth: String
    private let responses: [String]

    init(auth: String = #"{"loggedIn":true}"#, responses: [String] = []) {
        self.auth = auth; self.responses = responses
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func run(executable: URL, arguments: [String], stdin: Data, workingDirectory: URL,
             environment: [String: String], timeout: Duration) async throws -> ProcessResult {
        let n = calls.withLock { calls -> Int in
            calls.append(Call(executable: executable, arguments: arguments, environment: environment))
            return calls.filter { $0.arguments.first != "auth" }.count
        }
        let body: String
        if arguments.first == "auth" {
            body = auth
        } else {
            body = responses.isEmpty ? "" : responses[min(n, responses.count) - 1]
        }
        return ProcessResult(exitCode: 0, stdout: Data(body.utf8), stderr: Data(), timedOut: false)
    }
}
