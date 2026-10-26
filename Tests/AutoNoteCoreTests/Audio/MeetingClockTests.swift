import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct MeetingClockTests {
    @Test func timelineFromHostTime() {
        let host = FakeHostClock()
        let clock = MeetingClock(origin: host.hostTime(), host: host)
        #expect(clock.timeline(hostTime: host.hostTime(atSeconds: 2.5)).seconds == 2.5)
        host.advance(7); #expect(clock.now().seconds == 7)
    }
    @Test func hostTimeBeforeOriginIsNegative() {
        let host = FakeHostClock()
        host.advance(10)
        let clock = MeetingClock(origin: host.hostTime(), host: host)
        #expect(clock.timeline(hostTime: host.hostTime(atSeconds: 8)).seconds == -2)
    }
    @Test func machClockRoundTripsAndAdvances() {
        let clock = MachHostClock()
        let t0 = clock.hostTime()
        let ticks = clock.hostTicks(fromSeconds: 1.5)
        #expect(abs(clock.seconds(fromHostTicks: ticks) - 1.5) < 1e-6)
        #expect(clock.hostTime() >= t0)
    }
}

@Suite struct AudioFixturesTests {
    @Test func toneAndZerosHaveExpectedShape() {
        let t = AudioFixtures.tone(start: 1, seconds: 0.5, value: 7, track: .system)
        #expect(t.samples.count == 8_000 && t.samples.allSatisfy { $0 == 7 })
        #expect(t.track == .system && t.start.seconds == 1)
        #expect(AudioFixtures.zeros(start: 0, seconds: 0.25).samples == [Int16](repeating: 0, count: 4_000))
        #expect(AudioFixtures.sine(frequency: 440, amplitude: 0.5, seconds: 0.1, sampleRate: 48_000, channels: 2).count == 9_600)
    }
    @Test func fakeSourceEmitAndStartError() async throws {
        let source = FakeAudioSource(track: .mic, chunks: [AudioFixtures.tone(start: 0, seconds: 0.1)])
        let box = Box()
        try await source.start { box.append($0) }
        #expect(await source.isStarted)
        await source.emit(AudioFixtures.tone(start: 1, seconds: 0.1))
        #expect(box.count == 2)
        await source.stop()
        #expect(await source.stopCount == 1)
        #expect(await source.isStarted == false)

        let failing = FakeAudioSource(track: .mic, startError: FakeError(message: "denied"))
        await #expect(throws: FakeError.self) { try await failing.start { _ in } }
        #expect(await failing.isStarted == false)
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AudioChunk] = []
    func append(_ c: AudioChunk) { lock.withLock { items.append(c) } }
    var count: Int { lock.withLock { items.count } }
}
