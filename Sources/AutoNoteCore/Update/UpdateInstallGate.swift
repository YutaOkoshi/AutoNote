import Foundation

/// Work outside the queue and translation jobs that a quit would cut off (review L4).
public struct UpdateBusyWork: Equatable, Sendable {
    /// A whisper or translation model is downloading.
    public var modelDownload = false
    /// An audio file is being imported.
    public var audioImport = false
    /// An Automation's command is running.
    public var automation = false

    public init(modelDownload: Bool = false, audioImport: Bool = false, automation: Bool = false) {
        self.modelDownload = modelDownload
        self.audioImport = audioImport
        self.automation = automation
    }

    public static let none = UpdateBusyWork()
}

/// When a downloaded update may be swapped in (spec: 入れ替えの条件). Pure: the caller passes every input.
public enum UpdateInstallGate {
    public enum Decision: Equatable, Sendable {
        case install
        /// Not now; the reason is shown under 「再起動待ち」.
        case wait(String)
    }

    /// - Parameter userRequested: the person chose 「アップデートして再起動」. Then only the recorder counts: queue and
    ///   translation jobs are saved and continue after the restart, the window closes with the app, and the other work
    ///   in `busy` is theirs to cut short.
    public static func decide(recorder: RecorderState, queue: [QueueItemDTO], translationJobs: [TranslationJobState],
                              busy: UpdateBusyWork = .none, mainWindowOpen: Bool, userRequested: Bool) -> Decision {
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
        if busy.audioImport { return .wait("音声を取り込んでいます") }
        if busy.modelDownload { return .wait("モデルをダウンロードしています") }
        if busy.automation { return .wait("Automation を実行しています") }
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
/// After a check that could not reach GitHub, the next one waits `retryDelay` instead (review L7).
public enum UpdateSchedule {
    public static let interval: TimeInterval = 86_400
    /// How often the scheduler wakes to ask `isDue` (so a Mac that slept through the deadline catches up soon).
    public static let tick: TimeInterval = 3_600

    /// The wait after `failures` checks in a row could not connect: 1, 2, 4, 8 and 16 hours, then a day — at most
    /// five tries in the first day (the copy in `PrivacyCopy` says so).
    public static func retryDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        return min(interval, tick * pow(2, Double(min(failures, 10) - 1)))
    }

    /// - Parameter retryAt: set while checks keep failing to connect; it replaces the daily deadline.
    public static func isDue(lastCheckedAt: Date?, retryAt: Date? = nil, now: Date, interval: TimeInterval = interval) -> Bool {
        if let retryAt {
            // A clock set back by more than the longest wait: do not wait for a time that may be far away.
            return now >= retryAt || retryAt > now.addingTimeInterval(interval + 60)
        }
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
    private let retryAt: @Sendable () async -> Date?
    private let check: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    public init(clock: any QueueClock = SystemQueueClock(), tick: TimeInterval = UpdateSchedule.tick,
                interval: TimeInterval = UpdateSchedule.interval, isEnabled: @escaping @Sendable () async -> Bool,
                lastCheckedAt: @escaping @Sendable () async -> Date?, retryAt: @escaping @Sendable () async -> Date? = { nil },
                check: @escaping @Sendable () async -> Void) {
        self.clock = clock
        self.tick = tick
        self.interval = interval
        self.isEnabled = isEnabled
        self.lastCheckedAt = lastCheckedAt
        self.retryAt = retryAt
        self.check = check
    }

    public func start() {
        guard task == nil else { return }
        let clock = clock, tick = tick, interval = interval
        let isEnabled = isEnabled, lastCheckedAt = lastCheckedAt, retryAt = retryAt, check = check
        task = Task {
            while !Task.isCancelled {
                if await isEnabled(), UpdateSchedule.isDue(lastCheckedAt: await lastCheckedAt(), retryAt: await retryAt(),
                                                            now: clock.now(), interval: interval) {
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
