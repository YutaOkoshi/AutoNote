import AutoNoteCore
import Foundation
import Synchronization

/// A deterministic `TextCompleting`: reads the last `input` and the target language from the PFML3 prompt and
/// returns `phrases[text]` when given, else `"EN: <text>"` / `"JA: <text>"`. Records every call, can be slowed down,
/// made to fail, or made to hang until cancelled (to stand for a slow model).
public final class FakeTextCompleter: TextCompleting, @unchecked Sendable {
    public struct Failure: Error, Equatable {}

    public struct State: Sendable {
        public var loaded: URL?
        public var loads: [URL] = []
        public var unloads = 0
        public var prompts: [String] = []
        public var maxTokens: [Int] = []
        public var stops: [[String]] = []
    }

    private let state = Mutex(State())
    private let phrases: [String: String]
    private let delay: Duration
    private let failOnCall: Int?
    private let failLoad: Bool
    private let hang: Bool
    private let onCall: (@Sendable (Int) async -> Void)?
    private let promptLimit: Int?

    /// - Parameters:
    ///   - failOnCall: the 1-based `complete` call that throws `Failure` (later calls succeed again).
    ///   - hang: every `complete` waits until its task is cancelled.
    ///   - onCall: awaited at the start of every `complete` with its 1-based number (to act at an exact point).
    ///   - promptLimit: a prompt longer than this many characters throws `LlamaError.promptTooLong` (the model's
    ///     context, counted in characters).
    public init(phrases: [String: String] = [:], delay: Duration = .zero, failOnCall: Int? = nil,
                failLoad: Bool = false, hang: Bool = false, onCall: (@Sendable (Int) async -> Void)? = nil,
                promptLimit: Int? = nil) {
        self.phrases = phrases
        self.delay = delay
        self.failOnCall = failOnCall
        self.failLoad = failLoad
        self.hang = hang
        self.onCall = onCall
        self.promptLimit = promptLimit
    }

    public var snapshot: State { state.withLock { $0 } }

    public func load(modelURL: URL) async throws {
        if failLoad { throw Failure() }
        state.withLock {
            $0.loaded = modelURL
            $0.loads.append(modelURL)
        }
    }

    public func complete(prompt: String, stop: [String], maxTokens: Int) async throws -> String {
        let call = state.withLock { s -> Int in
            s.prompts.append(prompt)
            s.maxTokens.append(maxTokens)
            s.stops.append(stop)
            return s.prompts.count
        }
        await onCall?(call)
        if let promptLimit, prompt.count > promptLimit {
            throw LlamaError.promptTooLong(tokens: prompt.count, limit: promptLimit)
        }
        if hang {
            while true { try await Task.sleep(for: .seconds(60)) }
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if call == failOnCall { throw Failure() }
        guard let (text, target) = Self.lastInput(prompt) else { return "" }
        return phrases[text] ?? "\(target.uppercased()): \(text)"
    }

    public func unload() async {
        state.withLock {
            $0.loaded = nil
            $0.unloads += 1
        }
    }

    /// The text of the prompt's last `input` and the language of its last `output`.
    public static func lastInput(_ prompt: String) -> (text: String, target: String)? {
        guard let inputRange = prompt.range(of: "<|plamo:tag|>input", options: .backwards) else { return nil }
        let rest = prompt[inputRange.upperBound...]
        guard let msg = rest.range(of: "<|plamo:msg|>"),
              let out = rest.range(of: "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>") else { return nil }
        let text = String(rest[msg.upperBound..<out.lowerBound])
        let lang = rest[out.upperBound...].prefix { $0.isLetter }
        return (text, String(lang))
    }
}
