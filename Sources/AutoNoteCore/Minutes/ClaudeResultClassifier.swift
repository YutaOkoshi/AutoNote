import Foundation

public enum SummarizerError: Error, Equatable, Sendable {
    case claudeNotFound(path: String)
    case notLoggedIn
    case rateLimited(message: String)
    case contextExceeded(message: String)
    case timedOut
    case invalidOutput(message: String)
    case failed(exitCode: Int32, message: String)
}

/// Turns one `claude -p --output-format json` run into minutes or a failure class.
public enum ClaudeResultClassifier {
    /// Lower-case substrings matched against the stdout JSON `result` and stderr, checked in this order.
    /// Taken from strings inside the claude 2.1.310 executable; not yet confirmed against real failure output.
    static let patterns: [(kind: Kind, needles: [String])] = [
        (.notLoggedIn, ["not logged in", "run /login", "invalid api key", "authentication_error"]),
        (.rateLimited, ["hit your limit", "usage limit", "rate_limit", "rate limit"]),
        (.contextExceeded, ["prompt is too long", "context window", "context length", "too many tokens"]),
    ]

    enum Kind { case notLoggedIn, rateLimited, contextExceeded }

    static let messageLimit = 500

    private struct Envelope: Decodable {
        var isError: Bool?
        var subtype: String?
        var result: String?
    }

    private struct Structured: Decodable {
        var structuredOutput: MinutesOutput
    }

    private struct AuthStatus: Decodable {
        var loggedIn: Bool
    }

    public static func classify(_ result: ProcessResult) -> Result<MinutesOutput, SummarizerError> {
        if result.timedOut { return .failure(.timedOut) }
        let decoder = AutoNoteJSON.decoder()
        let isObject = (try? JSONSerialization.jsonObject(with: result.stdout)) is [String: Any]
        let envelope = isObject ? try? decoder.decode(Envelope.self, from: result.stdout) : nil
        var structuredError: String?
        if let envelope, envelope.isError == false, envelope.subtype == "success" {
            do {
                return .success(try decoder.decode(Structured.self, from: result.stdout).structuredOutput)
            } catch {
                structuredError = describe(error)
            }
        }

        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let resultText = envelope?.result ?? ""
        let haystack = (resultText + "\n" + stderr).lowercased()
        let message = String((resultText.isEmpty ? stderr : resultText)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(messageLimit))
        for (kind, needles) in patterns where needles.contains(where: haystack.contains) {
            switch kind {
            case .notLoggedIn: return .failure(.notLoggedIn)
            case .rateLimited: return .failure(.rateLimited(message: message))
            case .contextExceeded: return .failure(.contextExceeded(message: message))
            }
        }

        if let envelope {
            let reason = structuredError ?? "no structured_output"
            return .failure(.invalidOutput(message: "subtype=\(envelope.subtype ?? "nil"): \(reason)"))
        }
        return .failure(.failed(exitCode: result.exitCode, message: String(stderr.prefix(messageLimit))))
    }

    /// `claude auth status --json` succeeded and reported `"loggedIn": true`.
    public static func isLoggedIn(_ result: ProcessResult) -> Bool {
        guard result.exitCode == 0, !result.timedOut,
              let status = try? AutoNoteJSON.decoder().decode(AuthStatus.self, from: result.stdout) else { return false }
        return status.loggedIn
    }

    /// Describes a decoding failure by coding path only, so no output values leak into messages or logs.
    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "structured_output did not decode" }
        let path: [any CodingKey]
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): path = c.codingPath
        case .keyNotFound(let key, let c): path = c.codingPath + [key]
        @unknown default: path = []
        }
        let joined = path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return joined.isEmpty ? "structured_output did not decode" : "structured_output invalid at \(joined)"
    }
}
