import Foundation

/// How an Apple live engine decides where an utterance ends. Raw values are the CLI spellings.
public enum SegmentationStrategy: String, Codable, Sendable, CaseIterable {
    /// The engine's own progressive preset.
    case engineDefault = "default"
    /// The progressive preset plus the engine's frequent-finalization reporting option.
    case frequentFinalization = "frequent"
    /// The progressive preset, finalized by us at each `SilenceDetector` boundary.
    case silenceFinalize = "silence"

    /// The strategy the app uses (plan 04 Task 9 settles it from measurements).
    public static var current: SegmentationStrategy { .engineDefault }
}
