import Foundation
import Synchronization

/// Where one meeting's live summary session is (tests read it).
enum LiveSummaryPhase: Equatable {
    case sleeping(until: Date), calling, ended
}

/// Runs the live summary of each recorded meeting: one call per interval while there are new confirmed utterances,
/// at most one call in flight, rate-limit back-off, the queue's rate-limit round first, and one final call on stop.
/// Settings (on/off, interval) are read again on every tick; the summarizer is made and checked once per recording.
public actor LiveSummaryScheduler: LiveSummaryPort {
    public struct Dependencies: Sendable {
        public var settings: @Sendable () async -> Settings
        public var makeSummarizer: @Sendable (Settings) async throws -> any LiveSummarizer
        public var queueInRateLimitWait: @Sendable () async -> Bool
        public var save: @Sendable (MeetingID, LiveSummaryState) async -> Void
        public var log: @Sendable (String) -> Void
        public var clock: any QueueClock

        public init(settings: @Sendable @escaping () async -> Settings,
                    makeSummarizer: @Sendable @escaping (Settings) async throws -> any LiveSummarizer,
                    queueInRateLimitWait: @Sendable @escaping () async -> Bool,
                    save: @Sendable @escaping (MeetingID, LiveSummaryState) async -> Void,
                    log: @Sendable @escaping (String) -> Void,
                    clock: any QueueClock) {
            self.settings = settings
            self.makeSummarizer = makeSummarizer
            self.queueInRateLimitWait = queueInRateLimitWait
            self.save = save
            self.log = log
            self.clock = clock
        }
    }

    public static let maxBackoffSeconds: TimeInterval = 300
    public static let failureThreshold = 3
    public static let finalCallTimeoutSeconds: TimeInterval = 60

    private struct Session {
        var phase: LiveSummaryPhase?
        /// The newest confirmed list from the feed (the feed does not send it again on stop).
        var confirmed: [Utterance] = []
        var closed = false
        var cancelled = false
        /// The current sleep; cancelled to wake the session when the feed closes.
        var sleeper: Task<Void, Never>?
        var summarizer: (any LiveSummarizer)?
        /// Set once the summarizer cannot be made or claude is missing / logged out: nothing more this recording.
        var disabled = false
        var state: LiveSummaryState?
        var status: LiveSummaryStatus = .active
        var failures = 0
        var backoffWait: TimeInterval?
        var backoffUntil: Date?
        var tasks: [Task<Void, Never>] = []
    }

    private enum Outcome: Sendable {
        case success(LiveSummaryState)
        case failure(any Error)
    }

    private let deps: Dependencies
    private var sessions: [MeetingID: Session] = [:]
    private var paused = false
    private var subscribers: [UUID: AsyncStream<LiveSummaryUpdate>.Continuation] = [:]
    /// The newest update per meeting, handed to each new subscriber.
    private(set) var latestUpdates: [MeetingID: LiveSummaryUpdate] = [:]

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    // MARK: - Inputs

    /// Never waits: `.paused` holds every session's calls, `.resumed` / `.started` / `.stopped` release them.
    public func handle(_ e: RecordingEvent) {
        switch e {
        case .paused: paused = true
        case .resumed, .started, .stopped: paused = false
        default: break
        }
    }

    /// One session per meeting feed, until `feeds` ends or the calling task is cancelled.
    public func run(feeds: AsyncStream<LiveConfirmedFeed>) async {
        for await feed in feeds { begin(feed) }
        guard Task.isCancelled else { return }
        for id in sessions.keys where sessions[id]?.phase != .ended {
            sessions[id]?.cancelled = true
            sessions[id]?.sleeper?.cancel()
            for t in sessions[id]?.tasks ?? [] { t.cancel() }
        }
    }

    /// Each subscriber gets the newest update of every meeting first, then every new one.
    public func updates() -> AsyncStream<LiveSummaryUpdate> {
        let (stream, continuation) = AsyncStream<LiveSummaryUpdate>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        subscribers[id] = continuation
        for update in latestUpdates.values { continuation.yield(update) }
        return stream
    }

    // MARK: - Test hooks

    func phase(_ id: MeetingID) -> LiveSummaryPhase? { sessions[id]?.phase }

    var activeMeetings: Set<MeetingID> { Set(sessions.filter { $0.value.phase != .ended }.keys) }

    /// The newest confirmed list the session has read.
    func confirmed(_ id: MeetingID) -> [Utterance]? { sessions[id]?.confirmed }

    // MARK: - Session

    private func begin(_ feed: LiveConfirmedFeed) {
        let id = feed.meetingID
        if let existing = sessions[id], existing.phase != .ended { return }
        sessions[id] = Session()
        let reader = Task {
            for await list in feed.utterances { self.sessions[id]?.confirmed = list }
            self.close(id)
        }
        let driver = Task { await self.drive(id) }
        sessions[id]?.tasks = [reader, driver]
    }

    private func close(_ id: MeetingID) {
        sessions[id]?.closed = true
        sessions[id]?.sleeper?.cancel()
    }

    private func isRunning(_ id: MeetingID) -> Bool {
        guard let s = sessions[id] else { return false }
        return !s.closed && !s.cancelled
    }

    private func drive(_ id: MeetingID) async {
        let started = deps.clock.now()
        let initial = await deps.settings()
        if initial.liveSummaryEnabled {
            _ = await readySummarizer(id, initial)
        } else {
            deps.log("live summary: off (\(id.rawValue))")
        }
        var due = started.addingTimeInterval(Self.interval(initial))
        while isRunning(id) {
            sessions[id]?.phase = .sleeping(until: due)
            let (clock, until) = (deps.clock, due)
            let sleeper = Task { _ = try? await clock.sleep(until: until) }
            sessions[id]?.sleeper = sleeper
            await sleeper.value
            sessions[id]?.sleeper = nil
            guard isRunning(id) else { break }
            let (interval, called) = await tick(id)
            let now = deps.clock.now()
            let next = due.addingTimeInterval(interval)
            if next >= now {
                due = next
            } else if called {
                due = now                                   // one check right after a late call
            } else {
                let periods = (now.timeIntervalSince(due) / interval).rounded(.up)
                due = due.addingTimeInterval(interval * periods)  // the first period from now on, nothing queued
            }
        }
        if sessions[id]?.cancelled == false { await finalCall(id) }
        // Only the phase stays (the newest update is kept in `latestUpdates`).
        sessions[id]?.phase = .ended
        sessions[id]?.summarizer = nil
        sessions[id]?.confirmed = []
        sessions[id]?.tasks = []
    }

    /// Returns the interval read at its start and whether it called the summarizer.
    private func tick(_ id: MeetingID) async -> (interval: TimeInterval, called: Bool) {
        let settings = await deps.settings()
        let interval = Self.interval(settings)
        guard settings.liveSummaryEnabled, !paused, let s = sessions[id], !s.disabled else { return (interval, false) }
        if let until = s.backoffUntil, deps.clock.now() < until { return (interval, false) }
        if await deps.queueInRateLimitWait() {
            setStatus(id, .pausedForRateLimit)
            return (interval, false)
        }
        guard let summarizer = await readySummarizer(id, settings) else { return (interval, false) }
        guard let current = sessions[id],
              let request = LiveSummaryInputBuilder.request(previous: current.state ?? .empty, confirmed: current.confirmed) else {
            setStatus(id, .active)
            return (interval, false)
        }
        sessions[id]?.phase = .calling
        let outcome = await Self.call(request, summarizer: summarizer, clock: deps.clock).value
        await apply(outcome, to: id, interval: interval)
        return (interval, true)
    }

    /// After the feed closed and any call in flight has ended: one more call when there is something new,
    /// unless summaries are off, disabled, backing off or yielding to the queue. Capped at 60 s; a later result is dropped.
    private func finalCall(_ id: MeetingID) async {
        let settings = await deps.settings()
        guard settings.liveSummaryEnabled, let s = sessions[id], !s.disabled else { return }
        if let until = s.backoffUntil, deps.clock.now() < until { return }
        if await deps.queueInRateLimitWait() { return }
        guard let current = sessions[id],
              let request = LiveSummaryInputBuilder.request(previous: current.state ?? .empty, confirmed: current.confirmed),
              let summarizer = await readySummarizer(id, settings) else { return }
        sessions[id]?.phase = .calling
        let deadline = deps.clock.now().addingTimeInterval(Self.finalCallTimeoutSeconds)
        let call = Self.call(request, summarizer: summarizer, clock: deps.clock)
        guard let outcome = await Self.first(call, until: deadline, clock: deps.clock) else {
            deps.log("live summary: failed (timedOut) (\(id.rawValue))")
            return
        }
        await apply(outcome, to: id, interval: Self.interval(settings))
    }

    /// The session's summarizer, made and checked on first use; nil (and disabled, logged once) when that fails.
    private func readySummarizer(_ id: MeetingID, _ settings: Settings) async -> (any LiveSummarizer)? {
        guard let s = sessions[id], !s.disabled else { return nil }
        if let summarizer = s.summarizer { return summarizer }
        do {
            let summarizer = try await deps.makeSummarizer(settings)
            try await summarizer.checkReady()
            sessions[id]?.summarizer = summarizer
            return summarizer
        } catch {
            sessions[id]?.disabled = true
            deps.log("live summary: unavailable (\(Self.className(error))) (\(id.rawValue))")
            return nil
        }
    }

    private func apply(_ outcome: Outcome, to id: MeetingID, interval: TimeInterval) async {
        guard sessions[id] != nil else { return }
        switch outcome {
        case .success(let state):
            sessions[id]?.state = state
            sessions[id]?.failures = 0
            sessions[id]?.backoffWait = nil
            sessions[id]?.backoffUntil = nil
            sessions[id]?.status = .active
            await deps.save(id, state)
            emit(id)
        case .failure(let error):
            switch error as? SummarizerError {
            case .rateLimited:
                let wait = min((sessions[id]?.backoffWait ?? interval) * 2, Self.maxBackoffSeconds)
                sessions[id]?.backoffWait = wait
                sessions[id]?.backoffUntil = deps.clock.now().addingTimeInterval(wait)
                deps.log("live summary: rate limited, next in \(Int(wait))s (\(id.rawValue))")
                setStatus(id, .pausedForRateLimit)
            case .claudeNotFound, .notLoggedIn:
                sessions[id]?.disabled = true
                deps.log("live summary: unavailable (\(Self.className(error))) (\(id.rawValue))")
            default:
                let failures = (sessions[id]?.failures ?? 0) + 1
                sessions[id]?.failures = failures
                deps.log("live summary: failed (\(Self.className(error))) (\(id.rawValue))")
                if failures >= Self.failureThreshold { setStatus(id, .failing) }
            }
        }
    }

    // MARK: - Updates

    private func setStatus(_ id: MeetingID, _ status: LiveSummaryStatus) {
        guard let s = sessions[id], s.status != status else { return }
        sessions[id]?.status = status
        emit(id)
    }

    private func emit(_ id: MeetingID) {
        guard let s = sessions[id] else { return }
        let update = LiveSummaryUpdate(meetingID: id, state: s.state, status: s.status)
        latestUpdates[id] = update
        for continuation in subscribers.values { continuation.yield(update) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: - Helpers

    private static func interval(_ s: Settings) -> TimeInterval { TimeInterval(s.liveSummaryIntervalSeconds) }

    private static func className(_ error: any Error) -> String {
        (error as? SummarizerError).map(ClaudeCodeSummarizer.className) ?? "failed"
    }

    /// The call runs in its own task, so waking or cancelling the session never cancels it.
    /// `updatedAt` is when the result arrived.
    private static func call(_ r: LiveSummaryRequest, summarizer: any LiveSummarizer, clock: any QueueClock) -> Task<Outcome, Never> {
        Task.detached {
            do {
                var state = try await LiveSummaryStep.run(r, summarizer: summarizer, now: clock.now())
                state.updatedAt = clock.now()
                return .success(state)
            } catch {
                return .failure(error)
            }
        }
    }

    /// The task's value, or nil once `clock` reaches `deadline` first (the task keeps running; its value is dropped).
    private static func first<T: Sendable>(_ task: Task<T, Never>, until deadline: Date, clock: any QueueClock) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task.detached {
                _ = try? await clock.sleep(until: deadline)
                once.resume(nil)
            }
            Task.detached {
                let value = await task.value
                once.resume(value)
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation with the first value it is given and ignores the rest.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: T) {
        let pending = continuation.withLock { c -> CheckedContinuation<T, Never>? in
            defer { c = nil }
            return c
        }
        pending?.resume(returning: value)
    }
}
