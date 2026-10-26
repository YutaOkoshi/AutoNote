import Foundation
import os

/// Runs `Retention.purgeExpiredAudio` right after `start()` and then every 24 hours (要件書 §12).
public actor RetentionScheduler {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "RetentionScheduler")
    static let interval: TimeInterval = 86_400

    private let retention: Retention
    private let settings: SettingsStore
    private let clock: any QueueClock
    private var task: Task<Void, Never>?

    public init(retention: Retention, settings: SettingsStore, clock: any QueueClock = SystemQueueClock()) {
        self.retention = retention
        self.settings = settings
        self.clock = clock
    }

    public func start() {
        guard task == nil else { return }
        let retention = self.retention, settings = self.settings, clock = self.clock
        task = Task {
            // Deadlines advance from the first run, so a slow purge does not shift the daily schedule.
            var next = clock.now()
            while !Task.isCancelled {
                await Self.runOnce(retention: retention, settings: settings, now: clock.now())
                next = next.addingTimeInterval(Self.interval)
                do { try await clock.sleep(until: next) } catch { break }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private static func runOnce(retention: Retention, settings: SettingsStore, now: Date) async {
        let days: Int
        do {
            days = try await settings.load().audioRetentionDays
        } catch {
            logger.error("retention: settings unreadable, skipped")
            return
        }
        do {
            let purged = try await retention.purgeExpiredAudio(retentionDays: days, now: now)
            if !purged.isEmpty {
                logger.info("retention: purged audio of \(purged.map(\.rawValue).joined(separator: ","), privacy: .public)")
            }
        } catch {
            logger.error("retention: purge failed (\(String(describing: type(of: error)), privacy: .public))")
        }
    }
}
