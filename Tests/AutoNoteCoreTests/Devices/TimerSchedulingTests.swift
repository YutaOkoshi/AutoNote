import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct TimerSchedulingTests {
    private struct WaitTimedOut: Error {}

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func sleepFinishesWhenTimeAdvances() async throws {
        let timer = ManualTimerScheduler()
        let sleeper = Task { try await timer.sleep(seconds: 5) }
        try await waitUntil { timer.pendingCount == 1 }
        await timer.advance(by: 5)
        try await sleeper.value
        #expect(timer.pendingCount == 0)
    }

    @Test func cancelledSleepThrowsWithoutAdvance() async throws {
        let timer = ManualTimerScheduler()
        let sleeper = Task { try await timer.sleep(seconds: 5) }
        try await waitUntil { timer.pendingCount == 1 }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(timer.pendingCount == 0)
    }

    @Test func sleepInAlreadyCancelledTaskThrowsAndSchedulesNothing() async throws {
        let timer = ManualTimerScheduler()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await timer.sleep(seconds: 5)
        }
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(timer.pendingCount == 0)
        #expect(timer.scheduledCount == 0)
    }

    @Test func negativeAdvanceDoesNotMoveTimeBackwards() async {
        let timer = ManualTimerScheduler()
        await timer.advance(by: 3)
        await timer.advance(by: -2)
        #expect(timer.now == 3)
    }
}
