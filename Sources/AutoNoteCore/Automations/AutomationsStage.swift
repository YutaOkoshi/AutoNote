import Foundation
import os

/// Last queue stage: fires `minutes_generated` / `transcript_only` automations. It never throws (spec §14.5:
/// automations do not affect whether the minutes succeed); failures are logged and notified by the dispatcher.
public struct AutomationsStage: QueueStage {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "AutomationsStage")

    public let name = StageName.automations
    private let dispatcher: AutomationDispatcher
    private let vault: @Sendable () async -> (folder: URL, writer: VaultWriter)?

    public init(dispatcher: AutomationDispatcher, vault: @Sendable @escaping () async -> (folder: URL, writer: VaultWriter)?) {
        self.dispatcher = dispatcher
        self.vault = vault
    }

    public static func trigger(for status: MeetingStatus) -> AutomationTrigger? {
        switch status {
        case .minutesGenerated: .minutesGenerated
        case .transcriptOnly: .transcriptOnly
        default: nil
        }
    }

    /// Changes on every regeneration, so a regenerated note fires again.
    public static func dedupeKey(_ job: Job) -> String { "\(job.meeting.rawValue):\(job.generation)" }

    public func run(_ job: inout Job, context: StageContext) async throws {
        try Task.checkCancellation()
        let id = job.meeting
        let manifest: Manifest
        do { manifest = try await context.manifests.load(id) } catch {
            Self.logger.error("\(id.rawValue, privacy: .public): manifest unreadable, automations skipped")
            return
        }
        guard let trigger = Self.trigger(for: manifest.status) else { return }
        var file: URL?
        if let vault = await vault(), let record = await vault.writer.record(for: id) {
            file = vault.folder.appending(path: record.relativePath)
        }
        let minutesURL = context.paths.minutesFile(id)
        let json = trigger == .minutesGenerated && FileManager.default.fileExists(atPath: minutesURL.path) ? minutesURL : nil
        let ctx = AutomationContextBuilder.make(event: trigger, manifest: manifest, file: file, minutesJSON: json)
        let records = await dispatcher.dispatch(trigger, context: ctx, dedupeKey: Self.dedupeKey(job))
        let failed = records.filter { $0.skippedReason == nil && !$0.succeeded }.count
        Self.logger.info("\(id.rawValue, privacy: .public): \(records.count) automation(s), \(failed) failed")
    }
}
