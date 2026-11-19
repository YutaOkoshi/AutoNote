import Foundation

/// When a downloaded update may be swapped in (spec: 入れ替えの条件). Pure: the caller passes every input.
public enum UpdateInstallGate {
    public enum Decision: Equatable, Sendable {
        case install
        /// Not now; the reason is shown under 「再起動待ち」.
        case wait(String)
    }

    /// - Parameter userRequested: the person chose 「アップデートして再起動」. Then only the recorder counts: queue and
    ///   translation jobs are saved and continue after the restart, and the window closes with the app.
    public static func decide(recorder: RecorderState, queue: [QueueItemDTO], translationJobs: [TranslationJobState],
                              mainWindowOpen: Bool, userRequested: Bool) -> Decision {
        switch recorder {
        case .idle: break
        case .countdown: return .wait("録音の開始を待っています")
        case .recording, .paused: return .wait("録音中です")
        case .grace: return .wait("録音の再接続を待っています")
        }
        if userRequested { return .install }
        if queue.contains(where: { $0.state == JobState.pending.rawValue || $0.state == JobState.running.rawValue }) {
            return .wait("議事録を作っています")
        }
        if translationJobs.contains(where: isBusy) { return .wait("翻訳しています") }
        if mainWindowOpen { return .wait("ウィンドウを閉じると再起動します") }
        return .install
    }

    private static func isBusy(_ job: TranslationJobState) -> Bool {
        switch job {
        case .queued, .running, .waitingForRecording, .waitingForTranscription: true
        case .failed: false
        }
    }
}

/// Whether the daily check is due: never checked, 24 hours passed, or the clock moved back past the last check.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 86_400
    /// How often the scheduler wakes to ask `isDue` (so a Mac that slept through the deadline catches up soon).
    public static let tick: TimeInterval = 3_600

    public static func isDue(lastCheckedAt: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let last = lastCheckedAt else { return true }
        if last > now.addingTimeInterval(60) { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

/// Wakes at `start()` and then every `tick`, and runs `check` when `isDue` says so and updates are on.
public actor UpdateScheduler {
    private let clock: any QueueClock
    private let tick: TimeInterval
    private let interval: TimeInterval
    private let isEnabled: @Sendable () async -> Bool
    private let lastCheckedAt: @Sendable () async -> Date?
    private let check: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    public init(clock: any QueueClock = SystemQueueClock(), tick: TimeInterval = UpdateSchedule.tick,
                interval: TimeInterval = UpdateSchedule.interval, isEnabled: @escaping @Sendable () async -> Bool,
                lastCheckedAt: @escaping @Sendable () async -> Date?, check: @escaping @Sendable () async -> Void) {
        self.clock = clock
        self.tick = tick
        self.interval = interval
        self.isEnabled = isEnabled
        self.lastCheckedAt = lastCheckedAt
        self.check = check
    }

    public func start() {
        guard task == nil else { return }
        let clock = clock, tick = tick, interval = interval
        let isEnabled = isEnabled, lastCheckedAt = lastCheckedAt, check = check
        task = Task {
            while !Task.isCancelled {
                if await isEnabled(), UpdateSchedule.isDue(lastCheckedAt: await lastCheckedAt(), now: clock.now(),
                                                            interval: interval) {
                    await check()
                }
                do { try await clock.sleep(until: clock.now().addingTimeInterval(tick)) } catch { break }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
