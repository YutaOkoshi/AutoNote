import Foundation

/// Streams input-device events. The Core Audio listener and the power and timer callbacks only enqueue an `Input`;
/// one serial loop inside the actor handles them in order (snapshot -> DeviceListDiff -> WakeSuppression).
/// Recordings that span a sleep are out of scope here (Y18).
public actor DeviceMonitor {
    private enum Input: Sendable {
        case hardwareChanged
        case power(PowerEvent)
        case windowEnded(generation: Int)
    }

    private let hardware: any AudioHardwareQuerying
    private let power: any SleepWakeObserving
    private let timer: any TimerScheduling
    private let wakeWindowSeconds: Double

    private var diff = DeviceListDiff()
    private var suppression = WakeSuppression()
    private var connectedDevices: [DeviceIdentity] = []
    private var presentAtSleep: Set<String>?
    private var windowTimer: (any CancellableTimer)?
    private var windowGeneration = 0

    private var observation: (any HardwareObservation)?
    private var inputs: AsyncStream<Input>.Continuation?
    private var loop: Task<Void, Never>?
    private var powerForwarder: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]
    /// Bumped by every `start()` and `stop()`, so inputs still in flight from an ended session are ignored.
    private var session = 0

    public init(hardware: any AudioHardwareQuerying, power: any SleepWakeObserving, timer: any TimerScheduling,
                wakeWindowSeconds: Double = 10) {
        self.hardware = hardware; self.power = power; self.timer = timer; self.wakeWindowSeconds = wakeWindowSeconds
    }

    deinit {
        observation?.cancel()
        windowTimer?.cancel()
        loop?.cancel()
        powerForwarder?.cancel()
        inputs?.finish()
        subscribers.values.forEach { $0.finish() }
    }

    /// Each subscriber first receives `.present(_, .launch)` for every connected candidate, then the shared live events.
    /// The first subscriber starts observing the hardware, which can throw; on failure nothing is left running.
    /// A subscriber that joins inside a post-wake window can later see `.removed` for a device it was never told about
    /// (a held removal) or a second `.present` (`.launch` then `.wake`). The intended use is one subscriber, the Coordinator.
    public func events() throws -> AsyncStream<DeviceEvent> {
        if observation == nil { try start() }
        let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream()
        for device in connectedDevices { continuation.yield(.present(device, .launch)) }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    public func connected() -> [DeviceIdentity] { connectedDevices }

    /// Cancels the hardware observation and finishes every subscriber's stream. A later `events()` starts afresh.
    public func stop() {
        session += 1
        observation?.cancel(); observation = nil
        inputs?.finish(); inputs = nil
        loop?.cancel(); loop = nil
        powerForwarder?.cancel(); powerForwarder = nil
        windowTimer?.cancel(); windowTimer = nil
        let finishing = subscribers.values
        subscribers = [:]
        finishing.forEach { $0.finish() }
        diff = DeviceListDiff(); suppression = WakeSuppression(); connectedDevices = []; presentAtSleep = nil
    }

    private func start() throws {
        let (stream, continuation) = AsyncStream<Input>.makeStream()
        // Observe before the first snapshot so no change between the two is missed.
        observation = try hardware.observeDeviceList { continuation.yield(.hardwareChanged) }
        inputs = continuation
        apply(diff.update(with: hardware.snapshot()))
        let powerEvents = power.events()       // subscribe now, not inside the task, so no event is lost
        powerForwarder = Task {
            for await event in powerEvents { continuation.yield(.power(event)) }
        }
        session += 1
        let token = session
        loop = Task { [weak self] in
            for await input in stream { await self?.handle(input, session: token) }
        }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func handle(_ input: Input, session token: Int) {
        guard token == session, observation != nil else { return }
        switch input {
        case .hardwareChanged:
            let change = diff.update(with: hardware.snapshot())
            apply(change)
            let passed = suppression.filter(added: change.added, removed: change.removed)
            broadcast(passed.removed.map(DeviceEvent.removed) + passed.added.map(DeviceEvent.added))
        case .power(.willSleep):
            presentAtSleep = Set(connectedDevices.map(\.deviceUID))
        case .power(.didWake):
            suppression.didWake(present: presentAtSleep ?? Set(connectedDevices.map(\.deviceUID)))
            presentAtSleep = nil
            windowTimer?.cancel()
            windowGeneration += 1
            let generation = windowGeneration
            let inputs = self.inputs
            windowTimer = timer.schedule(after: wakeWindowSeconds) { inputs?.yield(.windowEnded(generation: generation)) }
        case .windowEnded(let generation):
            guard generation == windowGeneration else { return }
            windowTimer = nil
            broadcast(suppression.endWindow(current: connectedDevices))
        }
    }

    private func apply(_ change: (added: [DeviceIdentity], removed: [DeviceIdentity])) {
        let removedUIDs = Set(change.removed.map(\.deviceUID))
        connectedDevices.removeAll { removedUIDs.contains($0.deviceUID) }
        connectedDevices.append(contentsOf: change.added)
    }

    private func broadcast(_ events: [DeviceEvent]) {
        for event in events {
            for continuation in subscribers.values { continuation.yield(event) }
        }
    }
}
