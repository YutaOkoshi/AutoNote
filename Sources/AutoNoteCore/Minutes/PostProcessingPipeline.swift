import Foundation

/// The standard post-processing stages (spec §8.1). Plan 06 adds an `automations` stage on top, either in the
/// array it hands to `PostProcessingQueue(paths:stages:activity:gate:)` or via `register(_:)`.
public enum PostProcessingPipeline {
    /// `transcribe`, `summarize`, `write_vault`, `update_index`, in that order, all sharing `services`.
    public static func standardStages(
        runner: FinalTranscriptionRunner,
        summarizer: @escaping @Sendable (Settings, AppPaths) async throws -> any Summarizer = SummarizerFactory.make,
        timeZone: TimeZone = .current,
        services: SharedVaultServices = .standard
    ) -> [any QueueStage] {
        [
            TranscribeStage(runner: runner, services: services),
            SummarizeStage(summarizer: summarizer, services: services),
            WriteVaultStage(timeZone: timeZone, services: services),
            UpdateIndexStage(services: services),
        ]
    }
}
