import Foundation

/// Runs every runnable automation registered for a trigger, in file order. `automations.json` is re-read on
/// every dispatch so an external edit applies to the next run. Each run's dedupe key is `"<dedupeKey>|<name>"`.
public struct AutomationDispatcher: Sendable {
    private let file: AutomationsFile
    private let runner: AutomationRunner
    private let notifier: (any UserNotifier)?

    public init(file: AutomationsFile, runner: AutomationRunner, notifier: (any UserNotifier)?) {
        self.file = file
        self.runner = runner
        self.notifier = notifier
    }

    public func dispatch(_ trigger: AutomationTrigger, context: AutomationContext, dedupeKey: String?) async -> [AutomationRunRecord] {
        var records: [AutomationRunRecord] = []
        for item in file.load().items where item.isRunnable && item.definition.on == trigger {
            let key = dedupeKey.map { "\($0)|\(item.definition.name)" }
            let record = await runner.run(item.definition, context: context, dedupeKey: key)
            records.append(record)
            if record.skippedReason == nil && !record.succeeded {
                await notifier?.post(.automationFailed(name: record.name, context.meetingID))
            }
        }
        return records
    }

    /// A manual run of one automation (`autonote automations run`, the settings screen). No dedupe key, so it
    /// always runs; no failure notification, since the caller shows the returned record.
    public func runOne(name: String, context: AutomationContext) async throws -> AutomationRunRecord {
        guard let item = file.load().items.first(where: { $0.definition.name == name }) else {
            throw AppCommandError.notFound("Automation が見つかりません: \(name)")
        }
        guard item.isRunnable else { throw AppCommandError.invalid(item.problem ?? "無効になっています") }
        return await runner.run(item.definition, context: context, dedupeKey: nil)
    }
}

public enum AutomationContextBuilder {
    public static func make(event: AutomationTrigger, manifest: Manifest, file: URL?, minutesJSON: URL?,
                            timeZone: TimeZone = .current) -> AutomationContext {
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f.string(from: manifest.startedAt)
        }
        return AutomationContext(event: event, meetingID: manifest.id, file: file, title: manifest.title ?? "",
                                 date: format("yyyy-MM-dd"), start: format("HH:mm"), minutesJSON: minutesJSON)
    }
}
