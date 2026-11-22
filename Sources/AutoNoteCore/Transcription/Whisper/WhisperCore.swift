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
    /// `.auto` decodes in the more probable of Japanese and English for these samples (judged on their first 30 s,
    /// like whisper's own detection); never any other language.
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

/// whisper's language probabilities for Japanese and English (the softmax over all its languages, so the two need not
/// add up to 1). AutoNote handles only these two, so `.auto` always picks one of them (要件: 「自動」は日本語と英語の判定).
public struct LanguageGuess: Equatable, Sendable {
    public var ja: Float
    public var en: Float

    public init(ja: Float, en: Float) {
        self.ja = ja; self.en = en
    }

    /// The more probable of the two; a tie goes to Japanese.
    public var language: Language { en > ja ? .en : .ja }

    /// The share of Japanese between the two (0.5 when both are zero).
    public var japaneseShare: Float { ja + en > 0 ? ja / (ja + en) : 0.5 }
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

    /// Japanese and English probabilities of the speech in the first 30 s of `samples` (16 kHz mono).
    func detectLanguage(_ samples: [Float]) async throws -> LanguageGuess
}
