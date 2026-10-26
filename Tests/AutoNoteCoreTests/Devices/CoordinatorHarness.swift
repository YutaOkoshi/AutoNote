import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

/// Shared fixture for the coordinator tests (Tasks 8 and 9): every dependency is a fake, `A` and `B` are registered.
/// Time is the manual timer's clock: `now()` is `base + timer.now`.
final class CoordinatorHarness: Sendable {
    struct WaitTimedOut: Error {}

    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    /// Registered Bluetooth headset (the auto-start device in most tests).
    static let deviceA = DeviceIdentity(raw: .fixtureBluetoothInput)!
    /// A second registered device (USB).
    static let deviceB = DeviceIdentity(raw: .fixtureUSBInput(uid: "AppleUSBAudioEngine:Fict:Head:SERIAL-B:1"))!

    let recorder = FakeRecordingControl()
    let notifier = FakeUserNotifier()
    let timer = ManualTimerScheduler()
    let storage = InMemoryRegistryStorage()
    let hardware = FakeAudioHardware()
    let power = FakeSleepWake()
    let monitor: DeviceMonitor
    let registry: DeviceRegistry
    let coordinator: AutoRecordCoordinator
    private let configBox: ConfigBox
    private let runTask = Mutex<Task<Void, Never>?>(nil)

    var A: DeviceIdentity { Self.deviceA }
    var B: DeviceIdentity { Self.deviceB }

    /// `registered` devices are stored in the registry before the coordinator exists (it reloads on every `.added`).
    init(config: AutoRecordConfig = AutoRecordConfig(countdownSeconds: 5, graceSeconds: 30, language: .ja,
                                                     startOnModelMatch: false),
         registered: [DeviceIdentity] = [deviceA, deviceB]) async throws {
        configBox = ConfigBox(config)
        let mac = FakeMacIdentity()
        let seed = DeviceRegistry(storage: storage, mac: mac)
        for device in registered { _ = try await seed.register(device) }
        registry = DeviceRegistry(storage: storage, mac: mac)
        monitor = DeviceMonitor(hardware: hardware, power: power, timer: timer)
        let timer = self.timer
        // Read on every `apply`, so `setConfig` takes effect on the next event.
        let box = configBox
        coordinator = AutoRecordCoordinator(
            monitor: monitor, registry: registry, recorder: recorder, notifier: notifier, timer: timer,
            config: { box.value.withLock { $0 } },
            now: { CoordinatorHarness.base.addingTimeInterval(timer.now) })
    }

    func setConfig(_ config: AutoRecordConfig) { configBox.value.withLock { $0 = config } }

    /// Polls `condition` (real time, at most 2 s). Used only where work runs in another task (reattach, `run()`).
    func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: Driving the coordinator directly

    /// `A` connects and the countdown runs out: the coordinator is recording on `A`.
    func startAutoRecording() async {
        await coordinator.handle(.added(A))
        await timer.advance(by: 5)
    }

    // MARK: Driving it through `run()` and the monitor

    /// Starts `run()` with `initial` connected and returns once the monitor has its subscriber
    /// (the built-in microphone is always present so `connected()` shows the subscription exists).
    func startRunning(initial: [RawAudioDevice] = []) async throws {
        hardware.setDevices([.fixtureBuiltInMicrophone] + initial)
        let coordinator = self.coordinator
        runTask.withLock { $0 = Task { await coordinator.run() } }
        try await waitUntil { await !monitor.connected().isEmpty }
    }

    /// Cancels `run()` and waits for it to return.
    func stopRunning() async {
        let task = runTask.withLock { task -> Task<Void, Never>? in defer { task = nil }; return task }
        task?.cancel()
        await task?.value
    }

    /// Adds `raw` to the fake hardware and fires the change, as Core Audio would on plug-in.
    func connect(_ raw: RawAudioDevice) {
        hardware.setDevices(hardware.snapshot() + [raw])
        hardware.fireChange()
    }

    /// `connect`, then waits until the running coordinator has finished handling one more device event
    /// (so `raw` must be an auto-record candidate and no post-wake window may hold the event).
    func connectAndSettle(_ raw: RawAudioDevice) async throws {
        let before = await coordinator.handledEvents
        connect(raw)
        try await waitUntil { await coordinator.handledEvents > before }
    }

    /// `disconnect`, then waits like `connectAndSettle`.
    func disconnectAndSettle(_ raw: RawAudioDevice) async throws {
        let before = await coordinator.handledEvents
        disconnect(raw)
        try await waitUntil { await coordinator.handledEvents > before }
    }

    /// Removes `raw` (by UID) from the fake hardware and fires the change.
    func disconnect(_ raw: RawAudioDevice) {
        hardware.setDevices(hardware.snapshot().filter { $0.deviceUID != raw.deviceUID })
        hardware.fireChange()
    }
}

private final class ConfigBox: Sendable {
    let value: Mutex<AutoRecordConfig>
    init(_ config: AutoRecordConfig) { value = Mutex(config) }
}
