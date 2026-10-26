import Foundation
import os

private let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "PostProcessingQueue")

extension PostProcessingQueue {
    /// Regenerates a meeting's minutes from `summarize` (bumping `generation`), as often as asked (spec §8.4).
    /// Unlike `retry`, which resumes a failed job where it failed, this re-runs a finished meeting's summary.
    /// Without `final.json` nothing happens; without a job, one is created with `transcribe` already done.
    public func regenerate(_ id: MeetingID) async {
        await ensureLoaded()
        guard FileManager.default.fileExists(atPath: paths.transcriptFile(id, .final).path) else {
            logger.notice("regenerate \(id.rawValue, privacy: .public): transcript_missing")
            return
        }
        let key = id.rawValue
        if jobs[key] == nil {
            // Held until the rerun below has reset it, so the loop never runs the fresh job at generation 0.
            rerunsInProgress.insert(key)
            defer { rerunsInProgress.remove(key) }
            await persist(Job(id: key, meeting: id, stages: StageName.all, completedStages: [StageName.transcribe],
                              state: .pending, attempts: 0, lastError: nil, notBefore: nil, createdAt: clock.now()))
            await rerunFromSummarize(id)
            return
        }
        await rerunFromSummarize(id)
    }

    private func rerunFromSummarize(_ id: MeetingID) async {
        do {
            try await rerun(id, from: StageName.summarize)
        } catch {
            logger.error("regenerate \(id.rawValue, privacy: .public): rerun failed (\(String(describing: error), privacy: .public))")
        }
    }

    /// Keeps a too-short recording after all (spec §5.9 「文字起こしする」): marks it `.recorded` and enqueues it.
    /// Throws `QueueError.notTooShort` for any other status.
    public func acceptShortRecording(_ id: MeetingID) async throws {
        let status = try await manifests.load(id).status
        guard status == .tooShort else { throw QueueError.notTooShort(status) }
        _ = try await manifests.update(id) { $0.status = .recorded }
        logger.info("acceptShortRecording \(id.rawValue, privacy: .public): recorded")
        await enqueue(id)
    }
    /// Deletes a meeting entirely (spec §12 「この会議を削除」, §5.8・§5.9 「破棄」): cancels its running stage, then
    /// `Retention.deleteMeeting` (Vault file and index line, app data, job file), then drops the job from the queue.
    /// On `RetentionError.outputFolderUnavailable` nothing is deleted and the (cancelled) job stays pending.
    public func delete(_ id: MeetingID) async throws {
        await ensureLoaded()
        let key = id.rawValue
        // Held so the loop cannot start another stage of this meeting while it is being deleted.
        rerunsInProgress.insert(key)
        defer { rerunsInProgress.remove(key) }
        while jobs[key]?.state == .running, let current = stepTask {
            // The one step in flight is this job's; cancelling it puts the job back to `.pending`.
            current.cancel()
            await current.value
        }
        let outputFolder = (try? await settingsStore.load())?.outputFolder
        try await Retention(paths: paths).deleteMeeting(id, outputFolder: outputFolder)
        jobs[key] = nil
        progress[key] = nil
        rateLimitRounds[key] = nil
        publish()
        logger.info("delete \(key, privacy: .public): removed from queue")
    }
}
