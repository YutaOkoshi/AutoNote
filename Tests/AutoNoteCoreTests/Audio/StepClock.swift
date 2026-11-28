import Foundation
import Synchronization
import Testing
@testable import AutoNoteCore
import AutoNoteTestSupport

/// The clock of a `MicrophoneSource` under test. It stands still unless the test moves it, so no wait of the recovery
/// (settle, stall, back-off, budget, zeros) runs out because the machine was busy: with the real clock and waits of
/// 30 to 600 ms, a test that was held up for a second saw rebuilds nobody asked for.
/// Every reading is a nanosecond after the one before, so "posted before the rebuild began" stays an order.
///
/// Whatever the source waits for by this clock needs `pass` or `reach` to come: a plain `eventuallyTrue` only sees
/// what happens without time (a rebuild of an engine found stopped; not the settle delay after a configuration change).
final class StepClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = Mutex<Duration>(.zero)

    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in
            offset.withLock { $0 += .nanoseconds(1); return base + $0 }
        }
    }
    var elapsed: Duration { offset.withLock { $0 } }
    func advance(_ by: Duration) { offset.withLock { $0 += by } }

    /// Set once a `pass` or `reach` with this clock ran out of `testPatience`. The later ones then return at once,
    /// so a source whose watchdog is dead costs its test one `testPatience`, not one for every wait in it.
    private let spent = Mutex(false)
    var isSpent: Bool { spent.withLock { $0 } }
    func markSpent() { spent.withLock { $0 = true } }
}

/// Lets `span` of the source's clock pass, 25 ms at a time (shorter than every wait of the test policies). After each
/// step the watchdog looks twice, so one look is wholly at the new time; with `fed` (the engine a feeder pushes into),
/// a callback is drained first, so no look finds time gone by without the callbacks that flowed in it.
/// Returns true, at once, when `done`; the clock then stays where it is and nothing more happens by itself.
///
/// The whole call has `testPatience` of real time. When that runs out the clock did not get to where the caller
/// asked, so whatever the test checks next ("nothing happened in 500 ms") would be about a time that never came:
/// the call records an issue (the test fails, at the line of the call) and marks the clock spent.
@discardableResult
func pass(_ span: Duration, _ time: StepClock, _ src: MicrophoneSource, fed engine: FakeMicrophoneEngine? = nil,
          until done: () async -> Bool = { false }, waitingFor condition: String? = nil,
          sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    guard !time.isSpent else { return await done() }       // already reported; see `StepClock.isSpent`
    let start = time.elapsed
    let end = start + span
    let patience = ContinuousClock.now + testPatience
    while time.elapsed < end {
        if await done() { return true }
        guard ContinuousClock.now < patience else {
            time.markSpent()
            let moved = time.elapsed - start, looks = await src.watchdogLooks
            Issue.record("""
                \(condition.map { "\($0) did not come" } ?? "only \(moved) of \(span) passed on the source's clock") \
                within \(testPatience) of real time (clock moved \(moved), watchdog looks so far: \(looks), \
                watching: \(await src.isWatching))
                """, sourceLocation: sourceLocation)
            return false
        }
        time.advance(.milliseconds(25))
        if let engine {
            // Nothing is drained while the engine is down or being rebuilt: time passes without callbacks then.
            let drained = src.health?.callbacks ?? 0
            await shortly(patience) {
                if (src.health?.callbacks ?? 0) > drained || !engine.isRunning { return true }
                if await src.isRebuilding { return true }
                return await done()
            }
        }
        let looks = await src.watchdogLooks
        await shortly(patience) {
            guard await src.isWatching, await src.watchdogLooks < looks + 2 else { return true }
            return await done()
        }
        if !(await src.isWatching) { try? await Task.sleep(for: .milliseconds(2)) }   // stopped or gave up: just time
    }
    return await done()
}

/// Moves the source's clock until `done` (an hour of it at most; `testPatience` of the real one, after which it
/// records an issue as `pass` does and returns false).
func reach(_ time: StepClock, _ src: MicrophoneSource, fed engine: FakeMicrophoneEngine? = nil,
           sourceLocation: SourceLocation = #_sourceLocation, _ done: () async -> Bool) async -> Bool {
    await pass(.seconds(3600), time, src, fed: engine, until: done, waitingFor: "what `reach` waits for",
               sourceLocation: sourceLocation)
}

private func shortly(_ patience: ContinuousClock.Instant, _ condition: () async -> Bool) async {
    while !(await condition()), ContinuousClock.now < patience {
        try? await Task.sleep(for: .milliseconds(2))
    }
}
