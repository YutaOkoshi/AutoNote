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
