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
    /// Lower-case substrings matched against an error envelope's `result` and stderr, checked in this order.
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

    private struct Structured<Output: Decodable>: Decodable {
        var structuredOutput: Output
    }

    private struct AuthStatus: Decodable {
        var loggedIn: Bool
    }

    /// `is_error == false` is claude's own success, so its `result` is the model's prose about the meeting:
    /// it is never pattern-matched nor quoted, only the coding path of what failed to decode is reported.
    /// Failure patterns run over the `result` of an `is_error == true` envelope plus stderr.
    public static func classify(_ result: ProcessResult) -> Result<MinutesOutput, SummarizerError> {
        classify(result, as: MinutesOutput.self)
    }

    /// `classify(_:)` for any `structured_output` shape (minutes, live summary, …).
    public static func classify<Output: Decodable & Sendable>(_ result: ProcessResult, as _: Output.Type) -> Result<Output, SummarizerError> {
        if result.timedOut { return .failure(.timedOut) }
        let decoder = AutoNoteJSON.decoder()
        let isObject = (try? JSONSerialization.jsonObject(with: result.stdout)) is [String: Any]
        let envelope = isObject ? try? decoder.decode(Envelope.self, from: result.stdout) : nil
        if let envelope, envelope.isError == false {
            var reason = "no structured_output"
            if envelope.subtype == "success" {
                do {
                    return .success(try decoder.decode(Structured<Output>.self, from: result.stdout).structuredOutput)
                } catch {
                    reason = describe(error)
                }
            }
            return .failure(.invalidOutput(message: "subtype=\(envelope.subtype ?? "missing"): \(reason)"))
        }

        let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = envelope?.isError == true
            ? (envelope?.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let haystack = (errorText + "\n" + stderr).lowercased()
        let message = String((errorText.isEmpty ? stderr : errorText).prefix(messageLimit))
        for (kind, needles) in patterns where needles.contains(where: haystack.contains) {
            switch kind {
            case .notLoggedIn: return .failure(.notLoggedIn)
            case .rateLimited: return .failure(.rateLimited(message: message))
            case .contextExceeded: return .failure(.contextExceeded(message: message))
            }
        }

        if let envelope, envelope.isError != true {
            return .failure(.invalidOutput(message: "subtype=\(envelope.subtype ?? "missing"): no is_error"))
        }
        let combined = [errorText, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return .failure(.failed(exitCode: result.exitCode, message: String(combined.prefix(messageLimit))))
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
