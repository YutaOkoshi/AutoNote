import Foundation

/// A whisper segment; times are seconds from the start of the samples passed to `WhisperCore.run`.
public struct WhisperSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// A token with its own timestamps (seconds from the start of the samples). Only filled in `.live` mode.
public struct TimedToken: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public enum WhisperDecodeMode: Sendable {
    /// Beam search: beam 5, best_of 5.
    case batch
    /// Greedy, best_of 1, token timestamps.
    case live
}

public struct WhisperRunRequest: Sendable {
    /// 16 kHz mono samples of one batch window (or live window).
    public var samples: [Float]
    /// Where decoding starts inside `samples` (whisper `offset_ms`).
    public var offsetSeconds: Double
    public var language: Language
    public var prompt: String?
    public var mode: WhisperDecodeMode
    /// Tokens of other scripts are never chosen while decoding (`.unrestricted` = the whole multilingual vocabulary).
    /// Only live decoding sets it (see ScriptRestriction.swift).
    public var scripts: ScriptRestriction

    public init(samples: [Float], offsetSeconds: Double, language: Language, prompt: String?, mode: WhisperDecodeMode,
                scripts: ScriptRestriction = .unrestricted) {
        self.samples = samples; self.offsetSeconds = offsetSeconds; self.language = language
        self.prompt = prompt; self.mode = mode; self.scripts = scripts
    }
}

public enum WhisperRunOutcome: Equatable, Sendable {
    case completed
    case aborted
}

/// One whisper decoding pass. `WhisperContext` is the real one; tests use `FakeWhisperCore`.
public protocol WhisperCore: Sendable {
    func run(
        _ r: WhisperRunRequest,
        onSegment: @Sendable @escaping (WhisperSegment, [TimedToken]) -> Void,
        onProgress: @Sendable @escaping (Double) -> Void,
        shouldAbort: @Sendable @escaping () -> Bool
    ) async throws -> WhisperRunOutcome
}
