import Foundation
import Synchronization
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

/// Thread-safe value shared between a test and the scheduler's dependencies.
private final class SharedValue<T: Sendable>: Sendable {
    private let storage: Mutex<T>
    init(_ value: T) { storage = Mutex(value) }
    var value: T { storage.withLock { $0 } }
    func set(_ value: T) { storage.withLock { $0 = value } }
    func mutate(_ body: (inout T) -> Void) { storage.withLock { body(&$0) } }
}

/// Drives one `LiveSummaryScheduler` with a fake clock and a scripted summarizer. Nothing sleeps on the wall clock
/// except `waitUntil`'s polling, which only waits for the scheduler to settle.
private struct Harness {
    let clock = FakeQueueClock()
    let summarizer: ScriptedLiveSummarizer
    let settings: SharedValue<Settings>
    let queueRateLimited = SharedValue(false)
    let saved = SharedValue<[(MeetingID, LiveSummaryState)]>([])
    let logs = SharedValue<[String]>([])
    let received = SharedValue<[LiveSummaryUpdate]>([])
    let inner = SharedValue<[MeetingID: AsyncStream<[Utterance]>.Continuation]>([:])
    /// True between `hold()` and `release()`: a parked call then counts as a settled `.calling` phase.
    let holding = SharedValue(false)
    let scheduler: LiveSummaryScheduler
    let feeds: AsyncStream<LiveConfirmedFeed>.Continuation
    let tasks: [Task<Void, Never>]

    static var on: Settings {
        var s = Settings()
        s.liveSummaryEnabled = true
        s.liveSummaryIntervalSeconds = 20
        return s
    }

    init(settings: Settings = Harness.on, summarizer: ScriptedLiveSummarizer = ScriptedLiveSummarizer()) async {
        self.summarizer = summarizer
        self.settings = SharedValue(settings)
        let (settingsBox, queueBox, savedBox, logsBox) = (self.settings, queueRateLimited, saved, logs)
        scheduler = LiveSummaryScheduler(.init(
            settings: { settingsBox.value },
            makeSummarizer: { _ in summarizer },
            queueInRateLimitWait: { queueBox.value },
            save: { id, state in savedBox.mutate { $0.append((id, state)) } },
            log: { line in logsBox.mutate { $0.append(line) } },
            clock: clock))
        let (stream, continuation) = AsyncStream<LiveConfirmedFeed>.makeStream()
        feeds = continuation
        let scheduler = self.scheduler
        let updates = await scheduler.updates()
        let receivedBox = received
        tasks = [Task { await scheduler.run(feeds: stream) },
                 Task { for await u in updates { receivedBox.mutate { $0.append(u) } } }]
    }

    func stop() {
        feeds.finish()
        for t in tasks { t.cancel() }
    }

    func start(_ id: MeetingID) async throws {
        let (stream, continuation) = AsyncStream<[Utterance]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        inner.mutate { $0[id] = continuation }
        feeds.yield(LiveConfirmedFeed(meetingID: id, utterances: stream))
        try await waitUntil {
            if case .sleeping = await scheduler.phase(id) { return true }
            return await scheduler.phase(id) == .ended
        }
    }

    func say(_ id: MeetingID, _ list: [Utterance]) async throws {
        inner.value[id]?.yield(list)
        try await waitUntil { await scheduler.confirmed(id) == list }
    }

    func finish(_ id: MeetingID) {
        inner.value[id]?.finish()
    }

    func hold() async {
        holding.set(true)
        await summarizer.hold()
    }

    func release() async {
        holding.set(false)
        await summarizer.release()
    }

    /// Moves the clock, then waits until the session sleeps toward a future deadline, is parked in a held call, or has ended.
    func advance(_ id: MeetingID, _ seconds: TimeInterval) async throws {
        clock.advance(by: seconds)
        try await settled(id)
    }

    func settled(_ id: MeetingID) async throws {
        try await waitUntil {
            switch await scheduler.phase(id) {
            case .sleeping(let until): return until > clock.now()
            case .calling: return holding.value ? await summarizer.inFlight > 0 : false
            case .ended: return true
            case nil: return false
            }
        }
    }

    func requests() async -> Int { await summarizer.requests.count }
    func latest(_ id: MeetingID) async -> LiveSummaryUpdate? { await scheduler.latestUpdates[id] }
}

@Suite struct LiveSummarySchedulerTests {
    let a = MeetingID(rawValue: "20261028-1000-aaaa")
    let b = MeetingID(rawValue: "20261028-1100-bbbb")

    private func line(_ n: Int, end: Double? = nil) -> Utterance {
        u(Double(n) * 10, .me, "発話 \(n)", end: end ?? Double(n) * 10 + 5)
    }

    private func lines(_ n: Int) -> [Utterance] { (1...n).map { line($0) } }

    @Test func offByDefaultMakesNoCalls() async throws {
        let h = await Harness(settings: Settings())
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(3))
        try await h.advance(a, 60)
        #expect(await h.requests() == 0)
        #expect(await h.summarizer.readyChecks == 0)
        #expect(h.logs.value.contains("live summary: off (\(a.rawValue))"))
        #expect(await h.latest(a) == nil)
    }

    @Test func firstCallAfterTheInterval() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 19)
        #expect(await h.requests() == 0)
        try await h.advance(a, 1)
        #expect(await h.requests() == 1)
        let update = try #require(await h.latest(a))
        #expect(update.meetingID == a && update.status == .active)
        #expect(update.state?.consumedThrough == 15)
        #expect(update.state?.updatedAt == h.clock.now())
        #expect(h.saved.value.count == 1 && h.saved.value.last?.0 == a && h.saved.value.last?.1 == update.state)
        // The subscriber got it, and a late subscriber is handed the latest at once.
        try await waitUntil { h.received.value == [update] }
        var late = await h.scheduler.updates().makeAsyncIterator()
        #expect(await late.next() == update)
    }

    @Test func noNewUtteranceNoCall() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        try await h.advance(a, 20)
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        #expect(h.saved.value.count == 1)
    }

    @Test func pausedSkipsCalls() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        await h.scheduler.handle(.paused(TimelineTime(seconds: 20)))
        try await h.say(a, lines(2))
        try await h.advance(a, 40)
        #expect(await h.requests() == 1)
        await h.scheduler.handle(.resumed(TimelineTime(seconds: 20)))
        try await h.advance(a, 20)
        #expect(await h.requests() == 2)
    }

    @Test func intervalIsReadEveryTick() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)                       // the first wait (20 s) was set at the start
        h.settings.mutate { $0.liveSummaryIntervalSeconds = 60 }
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        try await h.say(a, lines(2))
        try await h.advance(a, 20)                 // t = 40: the next tick is 20 + 60
        #expect(await h.requests() == 1)
        try await h.advance(a, 39)                 // t = 79
        #expect(await h.requests() == 1)
        try await h.advance(a, 1)                  // t = 80
        #expect(await h.requests() == 2)
    }

    @Test func readyCheckRunsOncePerRecording() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        #expect(await h.summarizer.readyChecks == 1)   // at the start, before any tick
        for n in 1...3 {
            try await h.say(a, lines(n))
            try await h.advance(a, 20)
        }
        #expect(await h.requests() == 3)
        #expect(await h.summarizer.readyChecks == 1)
    }

    @Test func readyCheckWaitsForTheFirstOnTickWhenTurnedOnMidRecording() async throws {
        let h = await Harness(settings: Settings())
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.summarizer.readyChecks == 0)
        h.settings.set(Harness.on)
        try await h.advance(a, 20)
        #expect(await h.summarizer.readyChecks == 1)
        #expect(await h.requests() == 1)
    }

    @Test func notLoggedInAtStartSilencesTheRecording() async throws {
        let h = await Harness(summarizer: ScriptedLiveSummarizer(ready: .notLoggedIn))
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(2))
        try await h.advance(a, 60)
        #expect(await h.requests() == 0)
        #expect(await h.summarizer.readyChecks == 1)
        #expect(await h.latest(a) == nil)
        #expect(h.received.value.isEmpty)
        #expect(h.logs.value == ["live summary: unavailable (notLoggedIn) (\(a.rawValue))"])
        h.finish(a)
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        #expect(await h.requests() == 0)
    }

    @Test func turningOffMidRecordingStopsCalls() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        h.settings.mutate { $0.liveSummaryEnabled = false }
        try await h.say(a, lines(2))
        try await h.advance(a, 40)
        #expect(await h.requests() == 1)
    }

    /// Review Focus 1: a call longer than the interval is followed by exactly one check, never a burst or a second call.
    @Test func slowCallIsFollowedByOneImmediateCheck() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        await h.hold()
        try await h.advance(a, 20)
        #expect(await h.scheduler.phase(a) == .calling)
        try await h.say(a, lines(2))
        try await h.advance(a, 45)                 // t = 65: two periods pass during the call
        #expect(await h.requests() == 1)
        #expect(await h.summarizer.maxConcurrent == 1)
        await h.release()
        try await waitUntil { await h.requests() == 2 }  // right after the slow call, without moving the clock
        try await h.settled(a)
        #expect(await h.scheduler.phase(a) == .sleeping(until: h.clock.now().addingTimeInterval(20)))
        try await h.advance(a, 19)                 // t = 84: no catch-up for the skipped periods
        #expect(await h.requests() == 2)
        #expect(await h.summarizer.maxConcurrent == 1)
        try await h.say(a, lines(3))
        try await h.advance(a, 1)                  // t = 85
        #expect(await h.requests() == 3)
    }

    @Test func clockJumpDoesNotQueueTicks() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        try await h.say(a, lines(2))
        try await h.advance(a, 205)                // t = 225, e.g. after a sleep of the Mac
        #expect(await h.requests() == 2)
        // One check right after the late call (t = 225), then the period restarts from there: no queued ticks.
        #expect(await h.scheduler.phase(a) == .sleeping(until: Samples.start.addingTimeInterval(245)))
    }

    @Test func rateLimitBacksOffDoublingUpTo300() async throws {
        let limited = Result<LiveSummaryOutput, SummarizerError>.failure(.rateLimited(message: "limit"))
        let h = await Harness(summarizer: ScriptedLiveSummarizer(results: Array(repeating: limited, count: 6)))
        defer { h.stop() }
        try await h.start(a)
        var said = 0
        func at(_ t: TimeInterval, _ expected: Int) async throws {
            said += 1
            try await h.say(a, lines(said))
            try await h.advance(a, t - h.clock.now().timeIntervalSince(Samples.start))
            #expect(await h.requests() == expected, "t = \(t)")
        }
        try await at(20, 1)
        #expect(await h.latest(a)?.status == .pausedForRateLimit)
        #expect(await h.latest(a)?.state == nil)
        #expect(h.logs.value.last == "live summary: rate limited, next in 40s (\(a.rawValue))")
        try await at(59, 1)
        try await at(60, 2)
        try await at(139, 2)
        try await at(140, 3)
        try await at(299, 3)
        try await at(300, 4)
        try await at(599, 4)
        try await at(600, 5)
        try await at(899, 5)
        try await at(900, 6)
        #expect(h.logs.value.last == "live summary: rate limited, next in 300s (\(a.rawValue))")
        #expect(await h.latest(a)?.status == .pausedForRateLimit)
    }

    @Test func rateLimitClearsAfterSuccess() async throws {
        let h = await Harness(summarizer: ScriptedLiveSummarizer(results: [.failure(.rateLimited(message: "limit"))]))
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.latest(a)?.status == .pausedForRateLimit)
        try await h.say(a, lines(2))
        try await h.advance(a, 39)                 // t = 59
        #expect(await h.requests() == 1)
        try await h.advance(a, 1)                  // t = 60
        #expect(await h.requests() == 2)
        #expect(await h.latest(a)?.status == .active)
        #expect(await h.latest(a)?.state != nil)
        try await h.say(a, lines(3))
        try await h.advance(a, 19)                 // t = 79: back on the 20-second period
        #expect(await h.requests() == 2)
        try await h.advance(a, 1)                  // t = 80
        #expect(await h.requests() == 3)
    }

    @Test func queueRateLimitPausesLiveSummary() async throws {
        let h = await Harness()
        defer { h.stop() }
        h.queueRateLimited.set(true)
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 0)
        #expect(await h.latest(a) == LiveSummaryUpdate(meetingID: a, state: nil, status: .pausedForRateLimit))
        h.queueRateLimited.set(false)
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        #expect(await h.latest(a)?.status == .active)
        #expect(await h.latest(a)?.state != nil)
    }

    @Test func threeFailuresShowFailing() async throws {
        let failed = Result<LiveSummaryOutput, SummarizerError>.failure(.failed(exitCode: 1, message: "boom"))
        let h = await Harness(summarizer: ScriptedLiveSummarizer(results: [failed, failed, failed]))
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        #expect(await h.latest(a) == nil)          // failure 1: nothing published, the last state (none) stays
        try await h.advance(a, 20)
        #expect(await h.requests() == 2)
        #expect(await h.latest(a) == nil)          // failure 2: still nothing
        try await h.advance(a, 20)
        #expect(await h.requests() == 3)
        #expect(await h.latest(a) == LiveSummaryUpdate(meetingID: a, state: nil, status: .failing))
        #expect(h.logs.value.filter { $0 == "live summary: failed (failed) (\(a.rawValue))" }.count == 3)
        try await h.advance(a, 20)
        #expect(await h.requests() == 4)
        #expect(await h.latest(a)?.status == .active)
        #expect(await h.latest(a)?.state?.consumedThrough == 15)
        #expect(h.saved.value.count == 1)
    }

    @Test func claudeNotFoundMidRecordingStops() async throws {
        let h = await Harness(summarizer: ScriptedLiveSummarizer(results: [.failure(.claudeNotFound(path: ""))]))
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        #expect(h.logs.value.last == "live summary: unavailable (claudeNotFound) (\(a.rawValue))")
        try await h.say(a, lines(2))
        try await h.advance(a, 60)
        #expect(await h.requests() == 1)
        h.finish(a)
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        #expect(await h.requests() == 1)           // no final call either
    }

    @Test func stopMakesOneFinalCallWithNewUtterances() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        try await h.say(a, lines(2))
        h.finish(a)
        try await waitUntil { await h.requests() == 2 }   // without moving the clock
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        #expect(h.saved.value.count == 2)
        #expect(h.saved.value.last?.1.consumedThrough == 25)
        #expect(await h.latest(a)?.state?.consumedThrough == 25)
        #expect(await h.scheduler.activeMeetings.isEmpty)
        try await h.advance(a, 60)
        #expect(await h.requests() == 2)
    }

    @Test func stopWithoutNewUtterancesMakesNoFinalCall() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        h.finish(a)
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        #expect(await h.requests() == 1)
        #expect(h.saved.value.count == 1)
        #expect(await h.scheduler.activeMeetings.isEmpty)
    }

    /// Review Focus 2: stopping during a call waits for it, then makes at most one final call.
    @Test func stopDuringCallWaitsThenFinalOnce() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        await h.hold()
        try await h.advance(a, 20)
        #expect(await h.scheduler.phase(a) == .calling)
        try await h.say(a, lines(2))
        h.finish(a)
        #expect(await h.requests() == 1)
        #expect(await h.scheduler.phase(a) == .calling)
        await h.release()
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        #expect(await h.requests() == 2)
        #expect(await h.summarizer.maxConcurrent == 1)
        // The held call's result was kept and the final call built on it.
        let requests = await h.summarizer.requests
        #expect(requests[1].previous.consumedThrough == 15)
        #expect(h.saved.value.map(\.1.consumedThrough) == [15, 25])
    }

    @Test func finalCallGivesUpAfterSixtySeconds() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        await h.hold()
        try await h.say(a, lines(2))
        h.finish(a)
        try await waitUntil { await h.summarizer.inFlight == 1 }
        h.clock.advance(by: 59)
        #expect(await h.scheduler.activeMeetings == [a])
        h.clock.advance(by: 1)
        try await waitUntil { await h.scheduler.activeMeetings.isEmpty }
        #expect(await h.scheduler.phase(a) == .ended)
        await h.release()
        try await waitUntil { await h.summarizer.inFlight == 0 }
        #expect(h.saved.value.count == 1)          // the late result is dropped
        #expect(await h.latest(a)?.state?.consumedThrough == 15)
    }

    @Test func noFinalCallWhileBackingOff() async throws {
        let h = await Harness(summarizer: ScriptedLiveSummarizer(results: [.failure(.rateLimited(message: "limit"))]))
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        #expect(await h.requests() == 1)
        try await h.say(a, lines(2))
        h.finish(a)
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        #expect(await h.requests() == 1)
    }

    @Test func noFinalCallWhileTheQueueWaitsOnTheRateLimit() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        h.queueRateLimited.set(true)
        try await h.say(a, lines(2))
        h.finish(a)
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        #expect(await h.requests() == 1)
    }

    /// Review Focus 3: a late final call of meeting A never feeds meeting B.
    @Test func meetingsDoNotShareState() async throws {
        let h = await Harness()
        defer { h.stop() }
        try await h.start(a)
        try await h.say(a, lines(1))
        try await h.advance(a, 20)
        await h.hold()
        try await h.say(a, lines(2))
        h.finish(a)                                // A's final call parks
        try await waitUntil { await h.summarizer.inFlight == 1 }
        try await h.start(b)
        try await h.say(b, [u(1, .other, "B の発話", end: 3)])
        h.clock.advance(by: 20)
        try await waitUntil { await h.requests() == 3 }
        try await waitUntil { await h.scheduler.phase(b) == .sleeping(until: Samples.start.addingTimeInterval(60)) }
        let requests = await h.summarizer.requests
        #expect(requests[2].previous == .empty)    // B's first call does not carry A's state
        #expect(requests[2].utterances.map(\.text) == ["B の発話"])
        #expect(requests[1].previous.consumedThrough == 15)
        await h.release()
        try await waitUntil { await h.scheduler.phase(a) == .ended }
        let saved = h.saved.value
        #expect(saved.filter { $0.0 == a }.map(\.1.consumedThrough) == [15, 25])
        #expect(saved.filter { $0.0 == b }.map(\.1.consumedThrough) == [3])
        #expect(await h.latest(a)?.meetingID == a)
        #expect(await h.latest(a)?.state?.consumedThrough == 25)
        #expect(await h.latest(b)?.state?.consumedThrough == 3)
        #expect(await h.scheduler.activeMeetings == [b])
    }
}
