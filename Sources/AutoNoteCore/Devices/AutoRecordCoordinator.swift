import Foundation
import os

public enum AutoRecordError: Error, Equatable, Sendable { case notRecording }

/// Wires device events, the registry, `RecorderStateMachine` and the recorder together (spec §5.9): countdown
/// auto-start, disconnect grace, manual recording, and the snapshots the menu bar shows.
/// Effects run serially on this actor in the order the state machine returned them. Awaiting the recorder lets other
/// calls interleave, so the in-flight start and reattach are held as tasks (`startTask`, `reattachTask`, Y4).
public actor AutoRecordCoordinator {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "devices")

    private let monitor: DeviceMonitor
    private let registry: DeviceRegistry
    private let recorder: any RecordingControl
    private let notifier: any UserNotifier
    private let timer: any TimerScheduling
    private let config: @Sendable () async -> AutoRecordConfig
    private let now: @Sendable () -> Date

    private var machine: RecorderStateMachine
    private var timerHandle: (any CancellableTimer)?
    private var startTask: Task<MeetingID, any Error>?
    private var reattachTask: Task<Void, Never>?
    /// Bumped by every reattach and every cancellation of one, so a stale outcome is dropped (Y22).
    private var reattachGeneration = 0
    /// Bumped by every `startRecording`, so a start that returns after its session ended is not applied.
    private var sessionGeneration = 0

    private var meetingID: MeetingID?
    private var startedAt: Date?
    private var deadline: Date?
    private var banner: String?
    /// Chosen while idle or counting down; used by the next recording, cleared when a session ends.
    private var pendingLanguage: Language?
    /// The language of the session in progress.
    private var sessionLanguage: Language?

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
        machine.config = await config()
        let selfStops = await recorder.selfStops()
        let events: AsyncStream<DeviceEvent>
        do {
            events = try await monitor.events()
        } catch {
            Self.logger.error("device monitor failed: \(String(describing: error), privacy: .public)")
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
        switch event {
        case .added(let device):
            await registry.reload()
            let entryID: String?
            if case .registered(let id, _) = await registry.match(device) { entryID = id } else { entryID = nil }
            // Unregistered devices are passed too: a returning origin in grace is recognized by its UID.
            await apply(.deviceConnected(device, autoStartEntryID: entryID))
            // Task 9: registration notice for `.unknown` / `.reRegistrationSuggested`.
        case .removed(let device):
            await apply(.deviceDisconnected(device))
        case .present(_, let reason):
            // Task 9: `.present` posts deviceAlreadyConnected for registered devices; never a countdown.
            Self.logger.debug("present (\(String(describing: reason), privacy: .public)) ignored")
        }
    }

    // MARK: Operations (menu, CLI, shortcuts)

    /// Records from the Mac's default input. Throws what the recorder's start threw (after the same cleanup as auto-start).
    public func manualStart(language: Language?) async throws {
        if let language, machine.state == .idle || machine.state == .countdown { pendingLanguage = language }
        if let error = await apply(.manualStart) { throw error }
    }

    public func stop(reason: StopReason = .manual) async { await apply(.manualStop, stopReason: reason) }
    public func pause() async { await apply(.pause) }
    public func resume() async { await apply(.resume) }
    public func cancelCountdown() async { await apply(.cancelCountdown) }

    public func bookmark(note: String?) async throws -> Bookmark {
        guard isInSession else { throw AutoRecordError.notRecording }
        return try await recorder.bookmark(note: note)
    }

    public func setLanguage(_ language: Language) async {
        if isInSession {
            sessionLanguage = language
            emitIfChanged()
            await recorder.setLanguage(language)
        } else {
            pendingLanguage = language
            emitIfChanged()
        }
    }

    /// Notice buttons. Task 9 fills this in.
    public func handle(_ action: UserNoticeAction) async {
        // Task 9
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

    /// A new subscription per call; it first receives the current value.
    public func snapshots() -> AsyncStream<RecorderSnapshot> {
        let (stream, continuation) = AsyncStream<RecorderSnapshot>.makeStream()
        continuation.yield(current())
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
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

    /// Returns the error of a start that failed during this apply (only `manualStart` uses it).
    @discardableResult
    private func apply(_ event: RecorderEvent, stopReason: StopReason = .manual) async -> (any Error)? {
        machine.config = await config()
        let from = machine.state
        let (to, effects) = machine.apply(event)
        if from != to {
            Self.logger.info(
                "\(from.rawValue, privacy: .public) -> \(to.rawValue, privacy: .public) on \(Self.name(of: event), privacy: .public)")
        }
        if to == .idle && from != .idle && from != .countdown { endSession() }
        // A grace that runs out is the only stop caused by the device; the rest use the caller's reason.
        let reason: StopReason = if from == .grace, case .timerFired = event { .deviceGone } else { stopReason }
        var startError: (any Error)?
        for effect in effects {
            if let error = await execute(effect, stopReason: reason) { startError = error }
        }
        emitIfChanged()
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
            await notifier.withdraw(id: "device.countdown")
        case .scheduleTimer(let seconds, let token):
            timerHandle?.cancel()
            timerHandle = timer.schedule(after: Double(seconds)) { [weak self] in
                await self?.apply(.timerFired(token: token))
            }
        case .cancelTimer:
            timerHandle?.cancel(); timerHandle = nil
        case .startRecording(let choice, let trigger):
            return await startRecording(choice, trigger)
        case .stopRecording:
            cancelReattach()
            // Let a start still in flight finish first, so the recorder sees the stop after it.
            _ = await startTask?.result
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
            await notifier.withdraw(id: "device.grace")
        }
        return nil
    }

    private func startRecording(_ choice: MicrophoneChoice, _ trigger: RecordingTrigger) async -> (any Error)? {
        sessionGeneration += 1
        let generation = sessionGeneration
        let language = pendingLanguage ?? machine.config.language
        sessionLanguage = language
        banner = nil; deadline = nil; meetingID = nil; startedAt = nil
        let device: DeviceRef? = if case .device(let identity) = choice { identity.deviceRef } else { nil }
        let recorder = self.recorder
        let task = Task { try await recorder.start(device: device, language: language, manual: trigger == .manual) }
        startTask = task
        emitIfChanged()   // "recording, starting": no meetingID yet (Y11)
        let result = await task.result
        if startTask == task { startTask = nil }
        // The session ended (stop, self-stop) while starting: its stop already waited for this start.
        guard generation == sessionGeneration, isInSession else { return nil }
        switch result {
        case .success(let id):
            meetingID = id; startedAt = now()
            return nil
        case .failure(let error):
            Self.logger.error("start failed: \(String(describing: error), privacy: .public)")
            await apply(.sessionEnded)
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
            guard !Task.isCancelled else { return }
            await self?.finishReattach(outcome, generation: generation)
        }
    }

    private func finishReattach(_ outcome: ReattachOutcome, generation: Int) {
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

    /// A recording, pause or grace just went back to idle.
    private func endSession() {
        sessionGeneration += 1
        cancelReattach()
        timerHandle?.cancel(); timerHandle = nil
        meetingID = nil; startedAt = nil; deadline = nil; banner = nil
        sessionLanguage = nil; pendingLanguage = nil
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
