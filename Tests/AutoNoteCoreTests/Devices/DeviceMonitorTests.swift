import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

/// Collects a monitor stream so tests can await events with a bounded wait (no wall-clock sleeps beyond a few ms).
private actor EventRecorder {
    private var buffer: [DeviceEvent] = []
    private(set) var finished = false

    nonisolated func start(_ stream: AsyncStream<DeviceEvent>) {
        Task {
            for await event in stream { await self.append(event) }
            await self.finish()
        }
    }

    private func append(_ event: DeviceEvent) { buffer.append(event) }
    private func finish() { finished = true }

    func take() -> DeviceEvent? { buffer.isEmpty ? nil : buffer.removeFirst() }
    var count: Int { buffer.count }
}

private func next(_ recorder: EventRecorder) async throws -> DeviceEvent {
    try await waitUntil { await recorder.count > 0 }
    return await recorder.take()!
}

private func recorder(_ monitor: DeviceMonitor) async throws -> EventRecorder {
    let r = EventRecorder()
    r.start(try await monitor.events())
    return r
}

@Suite struct DeviceMonitorTests {
    let mic = DeviceIdentity(raw: .fixtureBuiltInMicrophone)!
    let bt = DeviceIdentity(raw: .fixtureBluetoothInput)!
    let jack = DeviceIdentity(raw: .fixtureHeadphoneInput)!

    struct Rig {
        let hardware = FakeAudioHardware()
        let power = FakeSleepWake()
        let timer = ManualTimerScheduler()
        let monitor: DeviceMonitor
        init(devices: [RawAudioDevice]) {
            hardware.setDevices(devices)
            monitor = DeviceMonitor(hardware: hardware, power: power, timer: timer)
        }
        func set(_ devices: [RawAudioDevice]) { hardware.setDevices(devices); hardware.fireChange() }
        /// Sleep then wake, and wait until the monitor has opened the wake window (its timer is pending).
        func sleepAndWake() async throws {
            power.send(.willSleep); power.send(.didWake)
            try await waitUntil { timer.pendingCount == 1 }
        }
    }

    @Test func launchEmitsPresentForCandidatesOnly() async throws {
        let rig = Rig(devices: [.fixtureBuiltInMicrophone, .fixtureBluetoothInput, .fixtureBluetoothOutput, .fixtureAggregate])
        let events = try await recorder(rig.monitor)
        #expect(try await next(events) == .present(mic, .launch))
        #expect(try await next(events) == .present(bt, .launch))
        #expect(await rig.monitor.connected() == [mic, bt])
        await rig.monitor.stop()
        try await waitUntil { await events.finished }
        #expect(await events.count == 0)
    }

    @Test func addedAndRemovedAreStreamed() async throws {
        let rig = Rig(devices: [.fixtureBuiltInMicrophone])
        let events = try await recorder(rig.monitor)
        #expect(try await next(events) == .present(mic, .launch))
        rig.set([.fixtureBuiltInMicrophone, .fixtureHeadphoneInput])
        #expect(try await next(events) == .added(jack))
        rig.set([.fixtureBuiltInMicrophone])
        #expect(try await next(events) == .removed(jack))
        rig.set([.fixtureBuiltInMicrophone, .fixtureAggregate, .fixtureProcessTapAggregate])
        rig.set([.fixtureBuiltInMicrophone, .fixtureVirtual])
        rig.set([.fixtureBuiltInMicrophone, .fixtureHeadphoneInput])
        // Aggregates and virtual devices produced nothing: the next event is the jack.
        #expect(try await next(events) == .added(jack))
        await rig.monitor.stop()
    }

    @Test func reappearanceWithinWakeWindowIsNotAdded() async throws {
        let rig = Rig(devices: [.fixtureBluetoothInput])
        let events = try await recorder(rig.monitor)
        #expect(try await next(events) == .present(bt, .launch))
        try await rig.sleepAndWake()
        await rig.timer.advance(by: 3)
        rig.set([])
        try await waitUntil { await rig.monitor.connected().isEmpty }
        rig.set([.fixtureBluetoothInput])
        try await waitUntil { await rig.monitor.connected() == [bt] }
        await rig.timer.advance(by: 7)
        // Neither .removed nor .added came out; the window end reports bt as present after wake.
        #expect(try await next(events) == .present(bt, .wake))
        #expect(rig.timer.pendingCount == 0)
        await rig.monitor.stop()
        try await waitUntil { await events.finished }
        #expect(await events.count == 0)
    }

    @Test func reappearanceAfterWakeWindowIsAdded() async throws {
        let rig = Rig(devices: [.fixtureBluetoothInput])
        let events = try await recorder(rig.monitor)
        #expect(try await next(events) == .present(bt, .launch))
        try await rig.sleepAndWake()
        await rig.timer.advance(by: 2)
        rig.set([])
        try await waitUntil { await rig.monitor.connected().isEmpty }
        await rig.timer.advance(by: 10)
        #expect(try await next(events) == .removed(bt))
        rig.set([.fixtureBluetoothInput])
        #expect(try await next(events) == .added(bt))
        await rig.monitor.stop()
    }

    @Test func newDeviceInsideWakeWindowIsAdded() async throws {
        let rig = Rig(devices: [.fixtureBluetoothInput])
        let events = try await recorder(rig.monitor)
        #expect(try await next(events) == .present(bt, .launch))
        try await rig.sleepAndWake()
        rig.set([.fixtureBluetoothInput, .fixtureHeadphoneInput])
        #expect(try await next(events) == .added(jack))
        await rig.timer.advance(by: 10)
        #expect(try await next(events) == .present(bt, .wake))
        await rig.monitor.stop()
    }

    @Test func secondWakeRestartsTheWindow() async throws {
        let rig = Rig(devices: [.fixtureBluetoothInput])
        let events = try await recorder(rig.monitor)
        #expect(try await next(events) == .present(bt, .launch))
        try await rig.sleepAndWake()
        await rig.timer.advance(by: 8)
        rig.power.send(.willSleep); rig.power.send(.didWake)
        // The old timer is cancelled and a new one replaces it.
        try await waitUntil { rig.timer.scheduledCount == 2 && rig.timer.pendingCount == 1 }
        await rig.timer.advance(by: 9)                 // 17 s after the first wake, 9 s after the second
        #expect(rig.timer.pendingCount == 1)
        #expect(await events.count == 0)
        await rig.timer.advance(by: 1)
        #expect(try await next(events) == .present(bt, .wake))
        await rig.monitor.stop()
    }

    @Test func secondSubscriberGetsLaunchPresenceThenSharedEvents() async throws {
        let rig = Rig(devices: [.fixtureBuiltInMicrophone])
        let first = try await recorder(rig.monitor)
        #expect(try await next(first) == .present(mic, .launch))
        let second = try await recorder(rig.monitor)
        #expect(try await next(second) == .present(mic, .launch))
        rig.set([.fixtureBuiltInMicrophone, .fixtureHeadphoneInput])
        #expect(try await next(first) == .added(jack))
        #expect(try await next(second) == .added(jack))
        await rig.monitor.stop()
        try await waitUntil { await first.finished }
        try await waitUntil { await second.finished }
    }

    @Test func stopCancelsHardwareObservation() async throws {
        let rig = Rig(devices: [.fixtureBuiltInMicrophone])
        let events = try await recorder(rig.monitor)
        #expect(try await next(events) == .present(mic, .launch))
        #expect(!rig.hardware.observationCancelled)
        await rig.monitor.stop()
        #expect(rig.hardware.observationCancelled)
        try await waitUntil { await events.finished }
    }
}
