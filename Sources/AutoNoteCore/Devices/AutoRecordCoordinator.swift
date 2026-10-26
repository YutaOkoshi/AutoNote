import Foundation
import os

public enum AutoRecordError: Error, Equatable, Sendable { case notRecording }

/// Wires device events, the registry, `RecorderStateMachine` and the recorder together (spec §5.9): countdown
/// auto-start, disconnect grace, manual recording, and the snapshots the menu bar shows.
/// Every entry point (device events, operations, timer callbacks, self-stops, reattach completion) passes one FIFO
/// gate, so one `apply` and all its effects finish before the next begins, even across the recorder's `await`s.
/// A stop therefore always waits for a start in flight (Y4). The microphone reattach retries outside the gate
/// (`reattachTask`); only its completion re-enters.
///
/// The gate is not re-entrant. Effects call `UserNotifier` (`post`/`withdraw`), `RecordingControl`
/// (`start`/`stop`/`pause`/…) and the `config` closure while holding it, so those implementations must never
/// await a coordinator API (`handle`, `stop`, `snapshots()`, …) from inside such a call: that waits on the gate
/// it is running under and deadlocks silently. Plan 06's UI must dispatch notice actions and other callbacks as
/// separate `Task`s.
public actor AutoRecordCoordinator {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "devices")

    private let monitor: DeviceMonitor
    private let registry: DeviceRegistry
    private let recorder: any RecordingControl
    private let notifier: any UserNotifier
    private let timer: any TimerScheduling
    private let config: @Sendable () async -> AutoRecordConfig
    private let now: @Sendable () -> Date

    private static let countdownNoticeID = UserNotice.deviceConnectedCountdown(placeholderRef, seconds: 0).id
    private static let graceNoticeID = UserNotice.deviceGoneGrace(placeholderRef, seconds: 0).id
    private static let placeholderRef = DeviceRef(name: "", uid: "", transport: "")

    private var gate = OperationGate()
    /// Operations parked at the gate (tests use it to know a call is queued).
    private(set) var queuedOperations = 0
    /// Device events whose handling has finished (the harness waits on it).
    private(set) var handledEvents = 0

    private var machine: RecorderStateMachine
    private var timerHandle: (any CancellableTimer)?
    private var reattachTask: Task<Void, Never>?
    /// Bumped by every reattach and every cancellation of one, so a stale outcome is dropped (Y22).
    private var reattachGeneration = 0

    private var meetingID: MeetingID?
    private var startedAt: Date?
    private var deadline: Date?
    private var banner: String?
    /// Chosen while idle or counting down; used by the next recording, cleared when a session ends.
    private var pendingLanguage: Language?
    /// The language of the session in progress.
    private var sessionLanguage: Language?

    /// Devices asked about with `deviceSeenFirstTime`, by UID, so an answer given after unplugging can still register.
    private var askedToRegister: [String: DeviceIdentity] = [:]
    /// Devices with a `deviceAlreadyConnected` notice up, by UID.
    private var alreadyConnected: [String: DeviceRef] = [:]

    private var subscribers: [UUID: AsyncStream<RecorderSnapshot>.Continuation] = [:]
    private var lastEmitted: RecorderSnapshot?

    public init(monitor: DeviceMonitor, registry: DeviceRegistry, recorder: any RecordingControl,
                notifier: any UserNotifier, timer: any TimerScheduling,
                config: @Sendable @escaping () async -> AutoRecordConfig, now: @Sendable @escaping () -> Date = Date.init) {
        self.monitor = monitor; self.registry = registry; self.recorder = recorder; self.notifier = notifier
        self.timer = timer; self.config = config; self.now = now
        // Replaced by `config()` before the first `apply`; until then snapshots use the settings defaults.
        machine = RecorderStateMachine(config: Self.config(from: Settings()))
    }

    public static func config(from settings: Settings) -> AutoRecordConfig {
        AutoRecordConfig(countdownSeconds: settings.countdownSeconds, graceSeconds: settings.disconnectGraceSeconds,
                         language: settings.defaultLanguage, startOnModelMatch: settings.startOnModelMatch)
    }

    // MARK: Running

    /// Reads `monitor.events()` and `recorder.selfStops()` until the monitor's stream finishes or the task is cancelled.
    public func run() async {
        await registry.reload()
        await serialized {
            machine.config = await config()
            emitIfChanged()
        }
        let selfStops = await recorder.selfStops()
        let events: AsyncStream<DeviceEvent>
        do {
            events = try await monitor.events()
        } catch {
            Self.log("device monitor", error)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                for await _ in selfStops { await self.apply(.sessionEnded) }
            }
            for await event in events { await handle(event) }
            group.cancelAll()
        }
    }

    public func handle(_ event: DeviceEvent) async {
        await serialized {
            switch event {
            case .added(let device):
                await registry.reload()
                let match = await registry.match(device)
                let entryID: String?
                if case .registered(let id, _) = match { entryID = id } else { entryID = nil }
                // Unregistered devices are passed too: a returning origin in grace is recognized by its UID.
                await applyInGate(.deviceConnected(device, autoStartEntryID: entryID))
                switch match {
                case .unknown, .reRegistrationSuggested:   // asked whatever the state (§11.3)
                    askedToRegister[device.deviceUID] = device
                    await notifier.post(.deviceSeenFirstTime(device.deviceRef))
                case .registered, .ignored:
                    askedToRegister[device.deviceUID] = nil   // answered elsewhere (settings, another prompt)
                }
            case .removed(let device):
                if let ref = alreadyConnected.removeValue(forKey: device.deviceUID) {
                    await notifier.withdraw(id: UserNotice.deviceAlreadyConnected(ref).id)
                }
                await applyInGate(.deviceDisconnected(device))
            case .present(let device, let reason):
                // Y5: only a registered device while idle gets the notice; never a countdown (§11.1). Unregistered
                // ones (the built-in microphone every launch) get nothing.
                await registry.reload()
                guard case .registered = await registry.match(device), machine.state == .idle else {
                    Self.logger.debug("present (\(String(describing: reason), privacy: .public)) without notice")
                    break
                }
                alreadyConnected[device.deviceUID] = device.deviceRef
                await notifier.post(.deviceAlreadyConnected(device.deviceRef))
            }
            handledEvents += 1
        }
    }

    // MARK: Operations (menu, CLI, shortcuts)

    /// Records from the Mac's default input. Throws what the recorder's start threw (after the same cleanup as auto-start).
    public func manualStart(language: Language?) async throws {
        let error = await serialized { () async -> (any Error)? in
            if let language, !isInSession { pendingLanguage = language }
            return await applyInGate(.manualStart)
        }
        if let error { throw error }
    }

    public func stop(reason: StopReason = .manual) async { await apply(.manualStop, stopReason: reason) }
    public func pause() async { await apply(.pause) }
    public func resume() async { await apply(.resume) }
    public func cancelCountdown() async { await apply(.cancelCountdown) }

    public func bookmark(note: String?) async throws -> Bookmark {
        let result = await serialized { () async -> Result<Bookmark, any Error> in
            guard isInSession else { return .failure(AutoRecordError.notRecording) }
            do { return .success(try await recorder.bookmark(note: note)) } catch { return .failure(error) }
        }
        return try result.get()
    }

    public func setLanguage(_ language: Language) async {
        await serialized {
            if isInSession {
                sessionLanguage = language
                emitIfChanged()
                await recorder.setLanguage(language)
            } else {
                pendingLanguage = language
                emitIfChanged()
            }
        }
    }

    /// Notice buttons. Only the device cases are handled here; the rest belong to plan 06.
    public func handle(_ action: UserNoticeAction) async {
        await serialized {
            switch action {
            case .cancelCountdown:
                await applyInGate(.cancelCountdown)
            case .startNow(let ref):
                await startNow(ref)
            case .registerDevice(let ref, let answer):
                await answerRegistration(ref, answer)
            case .openMeeting, .retry, .resolveOverwrite, .transcribeTooShort, .discardTooShort, .recoverInterrupted,
                 .discardInterrupted, .openPrivacySettings:
                break
            }
        }
    }

    /// The caller holds the gate. Starts on a still-connected registered device without a countdown.
    private func startNow(_ ref: DeviceRef) async {
        guard let device = await monitor.connected().first(where: { $0.deviceUID == ref.uid }) else {
            Self.logger.info("start now: device no longer connected")
            return
        }
        await registry.reload()
        guard case .registered(let entryID, _) = await registry.match(device) else {
            Self.logger.info("start now: device is not registered")
            return
        }
        await applyInGate(.startForConnectedDevice(device, entryID: entryID))
    }

    /// The caller holds the gate. `.no` stores nothing, so the next connection asks again.
    private func answerRegistration(_ ref: DeviceRef, _ answer: RegisterAnswer) async {
        let connected = await monitor.connected().first(where: { $0.deviceUID == ref.uid })
        let asked = askedToRegister.removeValue(forKey: ref.uid)
        await notifier.withdraw(id: UserNotice.deviceSeenFirstTime(ref).id)
        guard let device = connected ?? asked else {
            Self.logger.info("registration answer for an unknown device ignored")
            return
        }
        await registry.reload()
        do {
            switch answer {
            case .yes:
                let modelMatch = await config().startOnModelMatch
                let entry = try await registry.register(device, startOnModelMatchDefault: modelMatch)
                // Still plugged in: the table decides (idle counts down, anything else ignores it).
                if connected != nil { await applyInGate(.deviceConnected(device, autoStartEntryID: entry.id)) }
            case .no:
                break
            case .never:
                try await registry.ignore(device)
            }
        } catch {
            // plan 06: surface save failures of a registration answer to the user
            Self.log("register", error)
        }
    }

    // MARK: Snapshots

    public func current() -> RecorderSnapshot {
        let state = machine.state
        let inSession = state == .recording || state == .paused || state == .grace
        return RecorderSnapshot(
            state: state, meetingID: inSession ? meetingID : nil, startedAt: inSession ? startedAt : nil,
            deviceName: machine.origin?.name, deadline: deadline, isManual: machine.trigger == .manual,
            language: currentLanguage, banner: banner)
    }

    /// A new subscription per call; it first receives the current value. Subscribing passes the gate, so it never
    /// observes (or publishes) the middle of an `apply`.
    public func snapshots() async -> AsyncStream<RecorderSnapshot> {
        await serialized {
            emitIfChanged()   // existing subscribers catch up first, so `lastEmitted` is the value sent below
            let (stream, continuation) = AsyncStream<RecorderSnapshot>.makeStream()
            continuation.yield(lastEmitted ?? current())
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
            return stream
        }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func emitIfChanged() {
        let snapshot = current()
        guard snapshot != lastEmitted else { return }
        lastEmitted = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private var isInSession: Bool {
        switch machine.state {
        case .recording, .paused, .grace: true
        case .idle, .countdown: false
        }
    }

    private var currentLanguage: Language {
        isInSession ? (sessionLanguage ?? machine.config.language) : (pendingLanguage ?? machine.config.language)
    }

    // MARK: Applying events

    /// FIFO admission (plan 02's `OperationGate`). Never call it from inside `body`: that would deadlock.
    private func serialized<T>(_ body: () async -> T) async -> T {
        if !gate.tryEnter() {
            queuedOperations += 1
            await withCheckedContinuation { gate.wait($0) }
            queuedOperations -= 1
        }
        defer { gate.leave() }
        return await body()
    }

    @discardableResult
    private func apply(_ event: RecorderEvent, stopReason: StopReason = .manual) async -> (any Error)? {
        await serialized { await applyInGate(event, stopReason: stopReason) }
    }

    /// Scheduled timers land here. Internal so tests can deliver a stale token.
    func timerFired(token: Int) async { await apply(.timerFired(token: token)) }

    /// The caller holds the gate. Returns the error of a start that failed during this apply (only `manualStart`
    /// uses it). `emit: false` is for the nested `sessionEnded` of a failed start, whose caller emits once.
    @discardableResult
    private func applyInGate(_ event: RecorderEvent, stopReason: StopReason = .manual, emit: Bool = true) async
        -> (any Error)? {
        machine.config = await config()
        let from = machine.state
        let (to, effects) = machine.apply(event)
        if from != to {
            Self.logger.info(
                "\(from.rawValue, privacy: .public) -> \(to.rawValue, privacy: .public) on \(Self.name(of: event), privacy: .public)")
        }
        if to == .idle && from != .idle && from != .countdown { endSession() }
        if from == .idle && to != .idle { await withdrawAlreadyConnected() }
        // A grace that runs out is the only stop caused by the device; the rest use the caller's reason.
        let reason: StopReason = if from == .grace, case .timerFired = event { .deviceGone } else { stopReason }
        var startError: (any Error)?
        for effect in effects {
            if let error = await execute(effect, stopReason: reason) { startError = error }
        }
        if emit { emitIfChanged() }
        return startError
    }

    private func execute(_ effect: RecorderEffect, stopReason: StopReason) async -> (any Error)? {
        switch effect {
        case .postCountdownNotice(let device, let seconds):
            banner = nil
            deadline = now().addingTimeInterval(Double(seconds))
            await notifier.post(.deviceConnectedCountdown(device.deviceRef, seconds: seconds))
        case .dismissCountdownNotice:
            deadline = nil
            await notifier.withdraw(id: Self.countdownNoticeID)
        case .scheduleTimer(let seconds, let token):
            timerHandle?.cancel()
            timerHandle = timer.schedule(after: Double(seconds)) { [weak self] in
                await self?.timerFired(token: token)
            }
        case .cancelTimer:
            timerHandle?.cancel(); timerHandle = nil
        case .startRecording(let choice, let trigger):
            return await startRecording(choice, trigger)
        case .stopRecording:
            cancelReattach()
            await recorder.stop(reason: stopReason)
        case .pauseRecording:
            await recorder.pause()
        case .resumeRecording:
            await recorder.resume()
        case .suspendMicrophone:
            cancelReattach()
            await recorder.detachMicrophone()
        case .reattachMicrophone(let device):
            reattach(device)
        case .showGraceBanner(let seconds):
            banner = Banner.grace(seconds: seconds)
            deadline = now().addingTimeInterval(Double(seconds))
            if let origin = machine.origin {
                await notifier.post(.deviceGoneGrace(origin.deviceRef, seconds: seconds))
            }
        case .clearGraceBanner:
            banner = nil; deadline = nil
            await notifier.withdraw(id: Self.graceNoticeID)
        }
        return nil
    }

    private func startRecording(_ choice: MicrophoneChoice, _ trigger: RecordingTrigger) async -> (any Error)? {
        let language = pendingLanguage ?? machine.config.language
        sessionLanguage = language
        banner = nil; deadline = nil; meetingID = nil; startedAt = nil
        let device: DeviceRef? = if case .device(let identity) = choice { identity.deviceRef } else { nil }
        emitIfChanged()   // "recording, starting": no meetingID yet (Y11)
        do {
            // Holding the gate: nothing else (a stop, a pause) reaches the recorder until this start returns.
            meetingID = try await recorder.start(device: device, language: language, manual: trigger == .manual)
            startedAt = now()
            return nil
        } catch {
            Self.log("start", error)
            await applyInGate(.sessionEnded, emit: false)   // inline: the gate is already held
            banner = Banner.startFailed
            return error
        }
    }

    private func reattach(_ device: DeviceIdentity) {
        cancelReattach()
        let generation = reattachGeneration
        let reattacher = MicrophoneReattacher(control: recorder, timer: timer)
        let uid = device.deviceUID
        reattachTask = Task { [weak self] in
            let outcome = await reattacher.reattach(uid: uid)
            guard !Task.isCancelled, let self else { return }
            await self.serialized { await self.finishReattach(outcome, generation: generation) }
        }
    }

    private func finishReattach(_ outcome: ReattachOutcome, generation: Int) async {
        guard generation == reattachGeneration else { return }
        reattachTask = nil
        guard isInSession, machine.state != .grace else { return }
        if case .device = outcome { return }
        banner = Banner.micFallback
        emitIfChanged()
    }

    private func cancelReattach() {
        reattachGeneration += 1
        reattachTask?.cancel(); reattachTask = nil
    }

    /// Leaving idle: "already connected, start?" no longer applies to any device.
    private func withdrawAlreadyConnected() async {
        let refs = alreadyConnected.values
        alreadyConnected = [:]
        for ref in refs { await notifier.withdraw(id: UserNotice.deviceAlreadyConnected(ref).id) }
    }

    /// A recording, pause or grace just went back to idle.
    private func endSession() {
        cancelReattach()
        timerHandle?.cancel(); timerHandle = nil
        meetingID = nil; startedAt = nil; deadline = nil; banner = nil
        sessionLanguage = nil; pendingLanguage = nil
    }

    /// Only the error's type is public; its description may hold paths or device names.
    private static func log(_ what: String, _ error: any Error) {
        logger.error("\(what, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
    }

    private static func name(of event: RecorderEvent) -> String {
        switch event {
        case .deviceConnected: "deviceConnected"
        case .deviceDisconnected: "deviceDisconnected"
        case .timerFired: "timerFired"
        case .cancelCountdown: "cancelCountdown"
        case .manualStart: "manualStart"
        case .manualStop: "manualStop"
        case .pause: "pause"
        case .resume: "resume"
        case .startForConnectedDevice: "startForConnectedDevice"
        case .sessionEnded: "sessionEnded"
        }
    }
}
