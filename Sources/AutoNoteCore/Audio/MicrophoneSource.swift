import Foundation
import CoreAudio
import os

/// When `MicrophoneSource` rebuilds its input after the engine stopped, the format changed or callbacks stopped.
public struct MicrophoneRecoveryPolicy: Sendable, Equatable {
    /// How often the source looks at the engine and the callback count.
    public var checkInterval: Duration
    /// After a configuration change, how long to let the hardware settle before judging the engine.
    public var settleDelay: Duration
    /// Running but no callback for this long (also right after a start or rebuild) counts as stalled.
    public var stallTimeout: Duration
    /// Wait before the first retry of a rebuild that brought no callback; doubled per further failure.
    public var retryDelay: Duration
    /// Rebuilds in a row that bring no callback before the source gives up (reported as a source failure).
    public var maxConsecutiveFailures: Int
    /// Rebuilds per recording, whatever their outcome, before the source gives up.
    public var maxRebuilds: Int
    /// With a held Bluetooth input (`MicrophoneInputHolding`): before a rebuild starts the engine, the held input must
    /// have delivered without a gap for this long (the headset settled on HFP)…
    public var holdSettle: Duration
    /// …waiting at most this long; then the rebuild goes on anyway.
    public var holdSettleTimeout: Duration
    /// After a rebuild, callbacks flowing this long without another rebuild give the `maxRebuilds` budget back, so a
    /// long meeting with now-and-then interruptions never runs out of it.
    public var rebuildBudgetReset: Duration
    /// Callbacks arrive but every sample was exactly zero for this long: rebuild. A real input always carries noise,
    /// so exact zeros mean a broken path or a headset's mute button; the two look the same, so these rebuilds spend
    /// none of the budget above and never end the source. Not while the recording is paused. nil: never rebuild for
    /// zeros. The wait doubles per rebuild…
    public var zeroTimeout: Duration?
    /// …up to this, and goes back to `zeroTimeout` once a non-zero sample arrives.
    public var zeroRetryMax: Duration
    /// Rebuilds for one stretch of zeros (waits of 5, 10 and 20 s: 5, 15 and 35 s into it); after that the input is
    /// taken to be muted and is left alone until a non-zero sample arrives. Nobody is told and it is not counted as
    /// lost audio: a muted headset does this every day. The seconds stay on record as `audio_health.zero_seconds`.
    public var maxZeroRebuilds: Int

    public init(checkInterval: Duration = .milliseconds(250), settleDelay: Duration = .milliseconds(300),
                stallTimeout: Duration = .seconds(2), retryDelay: Duration = .milliseconds(500),
                maxConsecutiveFailures: Int = 5, maxRebuilds: Int = 30,
                holdSettle: Duration = .milliseconds(300), holdSettleTimeout: Duration = .seconds(2),
                rebuildBudgetReset: Duration = .seconds(60),
                zeroTimeout: Duration? = .seconds(5), zeroRetryMax: Duration = .seconds(60), maxZeroRebuilds: Int = 3) {
        self.checkInterval = checkInterval; self.settleDelay = settleDelay; self.stallTimeout = stallTimeout
        self.retryDelay = retryDelay; self.maxConsecutiveFailures = maxConsecutiveFailures; self.maxRebuilds = maxRebuilds
        self.holdSettle = holdSettle; self.holdSettleTimeout = holdSettleTimeout
        self.rebuildBudgetReset = rebuildBudgetReset
        self.zeroTimeout = zeroTimeout; self.zeroRetryMax = zeroRetryMax; self.maxZeroRebuilds = maxZeroRebuilds
    }

    public static let standard = MicrophoneRecoveryPolicy()
}

/// Microphone input via `MicrophoneEngine` (production: `AVAudioEngine`), converted to 16 kHz mono chunks.
///
/// Refuses to touch the engine unless microphone access is already authorized. Engine calls run on a dedicated
/// serial queue; `stop` waits for `engine.stop()` at most `stopTimeout`.
///
/// Recovery: opening a Bluetooth headset's microphone switches it from A2DP to HFP, and when that lands while the
/// engine is starting, `AVAudioEngine` stops itself (`iounit configuration changed > stopping the engine`) and never
/// restarts. So while running, the source watches for a configuration change, a stopped engine and missing callbacks,
/// and then rebuilds: engine stop → re-resolve the device → `prepare` (re-reads the format) → new ring, converter
/// and drain → `start`. Chunks keep their host-time stamps, so the gap becomes silence on the track's timeline.
/// After `policy.maxConsecutiveFailures` rebuilds without a callback, it gives up and reports through `health`.
/// A Bluetooth input is also held open by `inputHold` for the whole recording: without it, every rebuild's engine stop
/// lets the headset fall back to A2DP and the next start's switch to HFP stops the new engine again (seen on the real
/// headset). A rebuild waits (bounded) until the held input runs steadily before it starts the engine.
public actor MicrophoneSource: AudioSource {
    public nonisolated let track: Track = .mic
    public nonisolated let health: SourceHealth? = SourceHealth()

    private enum State {
        case idle
        case starting
        case running
    }

    /// Everything one engine bring-up made; replaced by a rebuild.
    private struct Pipeline {
        var ring: AudioRingBuffer
        var drain: Task<Void, Never>
        var format: InputFormat
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "MicrophoneSource")

    private let deviceUID: String?
    private let clock: MeetingClock
    private let voiceProcessing: Bool
    private let permission: any MicrophonePermissionChecking
    private let engine: any MicrophoneEngine
    private let lookup: any AudioDeviceLookup
    private let stopTimeout: Duration
    private let policy: MicrophoneRecoveryPolicy
    private let inputHold: any MicrophoneInputHolding
    private let controlQueue = DispatchQueue(label: "com.yutaokoshi.autonote.mic.control", qos: .userInitiated)

    private var state: State = .idle
    private var stopRequestedWhileStarting = false
    /// Test hook: whether the last `stop` gave up waiting for `engine.stop()`.
    private(set) var lastStopTimedOut = false

    // While running.
    private var pipeline: Pipeline?
    private var onBuffer: (@Sendable (AudioChunk) -> Void)?
    private var watchdog: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var lastRecords = 0
    private var lastCallbackAt = ContinuousClock.now
    private var configurationChangedAt: ContinuousClock.Instant?
    private var lastRebuildStartedAt: ContinuousClock.Instant?
    private var consecutiveFailures = 0
    private var rebuilds = 0
    /// Rebuilds counted against `maxRebuilds`; back to 0 after `rebuildBudgetReset` of flowing callbacks.
    private var rebuildsInBudget = 0
    /// Since when callbacks have flowed without a rebuild in between (nil right after a rebuild until the first one).
    private var healthySince: ContinuousClock.Instant?
    private var nextRebuildAllowedAt = ContinuousClock.now
    private var gaveUp = false
    // The zero watch (`policy.zeroTimeout`): its own wait, apart from the stall budget above.
    private var lastNonZeroCallbacks = 0
    private var lastNonZeroAt = ContinuousClock.now
    private var zeroWait = Duration.zero
    private var nextZeroRebuildAt = ContinuousClock.now
    private var zeroRebuildsInStretch = 0
    /// Test hooks: when each rebuild for zeros began, and the wait before the next one.
    private(set) var zeroRebuildStarts: [ContinuousClock.Instant] = []
    var currentZeroWait: Duration { zeroWait }
    /// Whether `inputHold` holds a Bluetooth input for this recording.
    private var holdingInput = false

    public init(deviceUID: String?, clock: MeetingClock, voiceProcessing: Bool = false,
                permission: any MicrophonePermissionChecking = AVMicrophonePermission(),
                engine: any MicrophoneEngine = AVMicrophoneEngine(),
                lookup: any AudioDeviceLookup = CoreAudioDeviceLookup(),
                stopTimeout: Duration = .seconds(5),
                policy: MicrophoneRecoveryPolicy = .standard,
                inputHold: any MicrophoneInputHolding = NoMicrophoneInputHold()) {
        self.deviceUID = deviceUID; self.clock = clock; self.voiceProcessing = voiceProcessing
        self.permission = permission; self.engine = engine; self.lookup = lookup; self.stopTimeout = stopTimeout
        self.policy = policy; self.inputHold = inputHold
    }

    /// Safety net when the owner drops a running source without `stop()`: no waiting, the engine stops in the background.
    deinit {
        if case .running = state {
            watchdog?.cancel()
            pipeline?.drain.cancel()
            let engine = self.engine, hold = self.inputHold
            controlQueue.async { engine.stop(); engine.setConfigurationChangeHandler(nil); hold.release() }
        }
    }

    /// Test hook: rebuilds so far in this recording.
    var rebuildCount: Int { rebuilds }

    /// permission → UID → `engine.prepare` → ring → drain task → `engine.start` → watchdog.
    public func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws {
        guard case .idle = state else { throw AudioSourceError.alreadyStarted }
        let status = permission.status()
        guard status == .authorized else { throw AudioSourceError.microphonePermission(status) }
        let deviceID = try resolveDevice()
        state = .starting
        stopRequestedWhileStarting = false

        let engine = self.engine, voiceProcessing = self.voiceProcessing, hold = self.inputHold
        // Held before the engine opens the input, so rebuilds find the headset already on HFP.
        holdingInput = await controlQueue.runAwaiting(timeout: stopTimeout, { hold.hold(deviceID: deviceID) },
                                                      abandoned: { held in if held { hold.release() } }) ?? false
        let handler: @Sendable () -> Void = { [weak self] in
            let postedAt = ContinuousClock.now   // before the hop, so a rebuild in between can tell it is stale
            Task { await self?.configurationChanged(postedAt: postedAt) }
        }
        let format: InputFormat
        do {
            format = try await onControlQueue {
                engine.setConfigurationChangeHandler(handler)
                return try engine.prepare(deviceID: deviceID, voiceProcessing: voiceProcessing)
            }
        } catch {
            state = .idle
            await controlQueue.runAwaiting(timeout: stopTimeout) { engine.setConfigurationChangeHandler(nil) }
            await releaseHold()
            throw error
        }
        guard let ring = Self.makeRing(format), let drain = makeDrain(ring: ring, format: format, onBuffer: onBuffer) else {
            state = .idle
            await controlQueue.runAwaiting(timeout: stopTimeout) { engine.stop(); engine.setConfigurationChangeHandler(nil) }
            await releaseHold()
            throw AudioSourceError.unsupportedFormat
        }
        do {
            try await onControlQueue { try engine.start(writingTo: ring) }
        } catch {
            state = .idle
            await controlQueue.runAwaiting(timeout: stopTimeout) { engine.stop(); engine.setConfigurationChangeHandler(nil) }
            drain.cancel()
            await drain.value
            await releaseHold()
            throw error
        }
        pipeline = Pipeline(ring: ring, drain: drain, format: format)
        self.onBuffer = onBuffer
        resetRecoveryState()
        state = .running
        Self.logger.notice("mic engine started (\(Self.describe(format), privacy: .public)) \(engine.routeDescription(), privacy: .public)")
        watchdog = makeWatchdog()
        if stopRequestedWhileStarting { await stop() }
    }

    /// Watchdog and any rebuild end first; then `engine.stop()` on the control queue (bounded wait), then the drain
    /// task empties the ring and flushes.
    public func stop() async {
        switch state {
        case .idle: return
        case .starting: stopRequestedWhileStarting = true; return
        case .running:
            state = .idle
            watchdog?.cancel(); watchdog = nil
            if let rebuildTask { await rebuildTask.value }   // a rebuild sees `.idle` after its next await and stops
            rebuildTask = nil
            let engine = self.engine
            let finished = await controlQueue.runAwaiting(timeout: stopTimeout) { engine.stop(); engine.setConfigurationChangeHandler(nil) }
            lastStopTimedOut = !finished
            if !finished { Self.logger.error("engine stop timeout") }
            await releaseHold()
            if let pipeline {
                pipeline.drain.cancel()
                await pipeline.drain.value
                health?.addDroppedFrames(pipeline.ring.droppedFrames)
            }
            pipeline = nil
            onBuffer = nil
            if rebuilds > 0 {
                Self.logger.notice("mic stopped after \(self.rebuilds, privacy: .public) rebuild(s)\(self.gaveUp ? " (gave up)" : "", privacy: .public)")
            }
        }
    }

    // MARK: - Recovery

    private func resetRecoveryState() {
        lastRecords = 0
        lastCallbackAt = .now
        configurationChangedAt = nil
        lastRebuildStartedAt = nil
        consecutiveFailures = 0
        rebuilds = 0
        rebuildsInBudget = 0
        healthySince = nil
        nextRebuildAllowedAt = .now
        gaveUp = false
        lastNonZeroCallbacks = health?.nonZeroCallbacks ?? 0
        lastNonZeroAt = .now
        zeroWait = policy.zeroTimeout ?? .zero
        nextZeroRebuildAt = .now
        zeroRebuildsInStretch = 0
    }

    /// A notification posted before the latest rebuild began is about the engine that rebuild replaced: ignored.
    private func configurationChanged(postedAt: ContinuousClock.Instant) {
        guard case .running = state, !gaveUp else { return }
        if let started = lastRebuildStartedAt, postedAt <= started {
            Self.logger.notice("mic engine configuration change from before rebuild #\(self.rebuilds, privacy: .public) ignored")
            return
        }
        Self.logger.notice("mic engine configuration changed \(self.engine.routeDescription(), privacy: .public)")
        configurationChangedAt = .now
    }

    private func makeWatchdog() -> Task<Void, Never> {
        let interval = policy.checkInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.check()
            }
        }
    }

    /// One look at the engine. Decides whether a rebuild is due; never runs two rebuilds at once.
    private func check() async {
        guard case .running = state, !gaveUp, rebuildTask == nil else { return }
        let now = ContinuousClock.now
        let records = pipeline?.ring.recordsWritten ?? 0
        if records != lastRecords {
            lastRecords = records
            lastCallbackAt = now
            if consecutiveFailures > 0 {
                Self.logger.notice("mic callbacks are back after rebuild")
            }
            consecutiveFailures = 0
            let since = healthySince ?? now
            healthySince = since
            if rebuildsInBudget > 0, now - since >= policy.rebuildBudgetReset {
                Self.logger.notice("mic ran \(Self.seconds(now - since), privacy: .public) s without a rebuild: rebuild budget reset (\(self.rebuildsInBudget, privacy: .public) used)")
                rebuildsInBudget = 0
            }
        }
        let nonZero = health?.nonZeroCallbacks ?? 0
        if nonZero != lastNonZeroCallbacks {
            lastNonZeroCallbacks = nonZero
            lastNonZeroAt = now
            if zeroRebuildsInStretch > 0 {
                Self.logger.notice("mic input is non-zero again after \(self.zeroRebuildsInStretch, privacy: .public) rebuild(s) for zeros")
            }
            zeroRebuildsInStretch = 0
            zeroWait = policy.zeroTimeout ?? .zero
            nextZeroRebuildAt = now
        }
        // A paused recording writes nothing: zeros are left alone and are counted from the resume.
        if health?.isPaused == true { lastNonZeroAt = now }
        let engine = self.engine
        // Staleness first and alone: on a stale graph `AVAudioEngine.isRunning` can block for seconds while the engine
        // follows a new Bluetooth default input by itself (seen on the real headset).
        let stale = await onControlQueueValue { engine.needsRebuild }
        let running = stale ? true : await onControlQueueValue { engine.isRunning }
        // `stop()` (or a give-up) may have run while this check waited on the control queue.
        guard case .running = state, rebuildTask == nil, !gaveUp else { return }

        var reason: String?
        if let changedAt = configurationChangedAt {
            // Kept pending through a back-off, so a format change is never dropped.
            guard now - changedAt >= policy.settleDelay, now >= nextRebuildAllowedAt else { return }
            configurationChangedAt = nil
            let current = stale ? nil : await onControlQueueValue { engine.currentFormat() }
            guard case .running = state, rebuildTask == nil, !gaveUp else { return }
            // Missing callbacks after the change are left to the stall check below (`stallTimeout`): right after an
            // A2DP → HFP switch the first callback can take longer than the settle delay.
            if stale {
                reason = "input device changed"
            } else if pipeline == nil || !running {
                reason = "engine stopped after configuration change"
            } else if let current, current != pipeline?.format {
                reason = "input format changed to \(Self.describe(current))"
            } else {
                Self.logger.notice("mic engine kept running after configuration change (\(Self.describe(self.pipeline?.format), privacy: .public))")
            }
        } else if stale {
            reason = "input device changed"
        } else if pipeline == nil || !running {
            reason = "engine not running"
        } else if now - lastCallbackAt >= policy.stallTimeout {
            reason = "no callbacks for \(Self.seconds(now - lastCallbackAt)) s"
        }
        guard let reason else {
            // Nothing wrong with the engine. Callbacks that carry nothing but exact zeros get a rebuild of their own
            // kind: no budget, no giving up (the headset's mute button looks the same).
            if let zeroTimeout = policy.zeroTimeout, zeroRebuildsInStretch < policy.maxZeroRebuilds, lastRecords > 0,
               now - lastNonZeroAt >= zeroTimeout, now >= nextZeroRebuildAt, now >= nextRebuildAllowedAt {
                let zeros = "only zero samples for \(Self.seconds(now - lastNonZeroAt)) s"
                rebuildTask = Task { await self.rebuild(reason: zeros, forZeros: true) }
            }
            return
        }
        guard now >= nextRebuildAllowedAt else { return }
        if consecutiveFailures >= policy.maxConsecutiveFailures || rebuildsInBudget >= policy.maxRebuilds {
            await giveUp(reason: reason)
            return
        }
        rebuildTask = Task { await self.rebuild(reason: reason) }
    }

    /// `forZeros`: a rebuild of the zero watch. It spends none of the stall budget; if it leaves the engine down, the
    /// next look finds "engine not running" and the budgeted rebuilds take over.
    private func rebuild(reason: String, forZeros: Bool = false) async {
        defer { rebuildTask = nil }
        lastRebuildStartedAt = .now
        rebuilds += 1
        var backoff = policy.retryDelay
        if forZeros {
            zeroRebuildsInStretch += 1
            zeroRebuildStarts.append(.now)
        } else {
            rebuildsInBudget += 1
            healthySince = nil
            consecutiveFailures += 1
            // Exponential backoff for the next attempt if this one brings no callback.
            backoff = policy.retryDelay * (1 << min(consecutiveFailures - 1, 6))
        }
        health?.noteRestart()
        let attempt = rebuilds
        Self.logger.notice("mic rebuild #\(attempt, privacy: .public) (\(reason, privacy: .public)) \(self.engine.routeDescription(), privacy: .public)")

        let engine = self.engine, timeout = self.stopTimeout
        if !(await controlQueue.runAwaiting(timeout: timeout) { engine.stop() }) {
            Self.logger.error("mic rebuild #\(attempt, privacy: .public): engine stop timeout")
        }
        if let old = pipeline {
            old.drain.cancel()
            await old.drain.value       // the old ring's tail is emitted at its own timeline position
            health?.addDroppedFrames(old.ring.droppedFrames)
        }
        pipeline = nil
        guard case .running = state, let onBuffer else { return }

        let deviceID: AudioDeviceID?
        do { deviceID = try resolveDevice() } catch {
            fail(attempt, "device lookup", error, backoff: backoff)
            return
        }
        // The held input may no longer be the one to hold: a new default input, or a device back with a new ID.
        let hold = inputHold
        let stillHeld = await controlQueue.runAwaiting(timeout: timeout, { hold.isHolding(deviceID: deviceID) },
                                                       abandoned: { _ in }) ?? false
        if !stillHeld {
            let wasHolding = holdingInput
            holdingInput = await controlQueue.runAwaiting(timeout: timeout, { hold.hold(deviceID: deviceID) },
                                                          abandoned: { held in if held { hold.release() } }) ?? false
            if wasHolding || holdingInput {
                Self.logger.notice("mic rebuild #\(attempt, privacy: .public): input hold \(self.holdingInput ? "moved to the current input" : "released (the input is not bluetooth)", privacy: .public)")
            }
            guard case .running = state else { return }
        }
        if holdingInput {
            await waitForSteadyInput(attempt)
            guard case .running = state else { return }
        }
        let voiceProcessing = self.voiceProcessing
        let result: Result<(InputFormat, AudioRingBuffer), any Error>? = await controlQueue.runAwaiting(timeout: timeout, {
            Result {
                let format = try engine.prepare(deviceID: deviceID, voiceProcessing: voiceProcessing)
                guard let ring = Self.makeRing(format) else {
                    engine.stop()
                    throw AudioSourceError.unsupportedFormat
                }
                try engine.start(writingTo: ring)
                return (format, ring)
            }
        }, abandoned: { _ in engine.stop() })
        // If `stop()` arrived meanwhile, it waits for this task, then stops the engine and drains `pipeline`; so a
        // started engine still gets its pipeline here, or what it already wrote into the ring would be lost.
        let stopping: Bool = if case .running = state { false } else { true }
        guard let result else {
            if stopping { return }
            fail(attempt, "prepare/start", AudioSourceError.timedOut(call: "AVAudioEngine.start"), backoff: backoff)
            return
        }
        switch result {
        case .failure(let error):
            await controlQueue.runAwaiting(timeout: timeout) { engine.stop() }
            if !stopping { fail(attempt, "prepare/start", error, backoff: backoff) }
        case .success(let (format, ring)):
            guard let drain = makeDrain(ring: ring, format: format, onBuffer: onBuffer) else {
                await controlQueue.runAwaiting(timeout: timeout) { engine.stop() }
                fail(attempt, "converter", AudioSourceError.unsupportedFormat, backoff: backoff)
                return
            }
            pipeline = Pipeline(ring: ring, drain: drain, format: format)
            lastRecords = 0
            lastCallbackAt = .now
            configurationChangedAt = nil
            if forZeros {
                zeroWait = min(zeroWait * 2, policy.zeroRetryMax)
                nextZeroRebuildAt = .now + zeroWait
                if zeroRebuildsInStretch >= policy.maxZeroRebuilds {
                    Self.logger.notice("mic input still delivers only zeros after \(self.zeroRebuildsInStretch, privacy: .public) rebuild(s): taken as muted, no more rebuilds until a non-zero sample arrives")
                }
            } else {
                nextRebuildAllowedAt = .now + backoff
            }
            Self.logger.notice("mic rebuild #\(attempt, privacy: .public) restarted the engine (\(Self.describe(format), privacy: .public))")
        }
    }

    private func fail(_ attempt: Int, _ step: String, _ error: any Error, backoff: Duration) {
        nextRebuildAllowedAt = .now + backoff
        Self.logger.error("mic rebuild #\(attempt, privacy: .public) failed at \(step, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    /// Stops trying: the engine is stopped, the track stays silent (the timeline fills it) and the owner learns of it.
    private func giveUp(reason: String) async {
        guard case .running = state, !gaveUp else { return }
        gaveUp = true
        watchdog?.cancel(); watchdog = nil
        let engine = self.engine
        await controlQueue.runAwaiting(timeout: stopTimeout) { engine.stop() }
        if let old = pipeline {
            old.drain.cancel()
            await old.drain.value
            health?.addDroppedFrames(old.ring.droppedFrames)
        }
        pipeline = nil
        await releaseHold()
        let message = "microphone input stopped and \(rebuilds) rebuild(s) did not bring it back (\(reason))"
        Self.logger.error("mic gave up after \(self.rebuilds, privacy: .public) rebuild(s): \(reason, privacy: .public)")
        health?.reportFailure(message)
    }

    /// Lets the held headset settle on HFP before the engine opens the input again; bounded by `holdSettleTimeout`.
    private func waitForSteadyInput(_ attempt: Int) async {
        let hold = inputHold, need = policy.holdSettle
        let started = ContinuousClock.now, deadline = started + policy.holdSettleTimeout
        while ContinuousClock.now < deadline {
            if hold.isSteady(for: need) {
                Self.logger.notice("mic rebuild #\(attempt, privacy: .public): held input steady after \(Self.seconds(.now - started), privacy: .public) s")
                return
            }
            guard case .running = state else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Self.logger.notice("mic rebuild #\(attempt, privacy: .public): held input not steady after \(Self.seconds(.now - started), privacy: .public) s; starting anyway")
    }

    private func releaseHold() async {
        guard holdingInput else { return }
        holdingInput = false
        let hold = inputHold
        await controlQueue.runAwaiting(timeout: stopTimeout) { hold.release() }
    }

    // MARK: - Helpers

    private func resolveDevice() throws -> AudioDeviceID? {
        guard let deviceUID else { return nil }
        guard let id = lookup.deviceID(forUID: deviceUID) else { throw AudioSourceError.deviceNotFound(uid: deviceUID) }
        return id
    }

    private static func makeRing(_ format: InputFormat) -> AudioRingBuffer? {
        guard format.channels > 0, format.sampleRate > 0, format.sampleRate.isFinite else { return nil }
        return AudioRingBuffer(channels: format.channels, capacityFrames: Int(format.sampleRate * 10), recordCapacity: 4096)
    }

    private func makeDrain(ring: AudioRingBuffer, format: InputFormat,
                           onBuffer: @Sendable @escaping (AudioChunk) -> Void) -> Task<Void, Never>? {
        guard let converter = try? SampleConverter(inputSampleRate: format.sampleRate, inputChannels: format.channels) else { return nil }
        return SourceDrain.makeTask(track: track, ring: ring, converter: converter, inputRate: format.sampleRate,
                                    clock: clock, health: health, onBuffer: onBuffer)
    }

    private static func describe(_ format: InputFormat?) -> String {
        guard let format else { return "no format" }
        return "\(Int(format.sampleRate.rounded())) Hz \(format.channels) ch"
    }

    private static func seconds(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.1f", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }

    private func onControlQueue<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        let queue = controlQueue
        return try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func onControlQueueValue<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        let queue = controlQueue
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work()) }
        }
    }
}
