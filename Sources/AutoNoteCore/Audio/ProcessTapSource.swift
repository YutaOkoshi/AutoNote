import Foundation
import CoreAudio
import Synchronization
import os

public struct SourceStatistics: Sendable, Equatable {
    public var callbacks: Int
    public var frames: Int
    public var droppedFrames: Int

    public init(callbacks: Int, frames: Int, droppedFrames: Int) {
        self.callbacks = callbacks; self.frames = frames; self.droppedFrames = droppedFrames
    }
}

/// When `ProcessTapSource` rebuilds its tap while recording. `checkInterval` is wall time; every other time is seconds
/// on the meeting timeline (`MeetingClock`), so tests move a fake clock instead of waiting.
public struct SystemTapRecoveryPolicy: Sendable, Equatable {
    /// How often the source looks at the callback count, the samples and the other processes.
    public var checkInterval: Duration
    /// Another process plays audio but no callback arrived for this long (also right after a rebuild): stalled.
    public var stallTimeout: Double
    /// Wait before the first retry of a stall rebuild that brought no callback; doubled per further failure.
    public var retryDelay: Double
    /// Stall rebuilds in a row that bring no callback before the source gives up (reported as a source failure).
    public var maxConsecutiveFailures: Int
    /// Stall rebuilds per recording before the source gives up…
    public var maxRebuilds: Int
    /// …unless callbacks flowed this long without another rebuild, which gives the budget back.
    public var rebuildBudgetReset: Double
    /// Another process plays audio but every sample was exactly zero for this long: rebuild. These rebuilds never
    /// end the source (the zeros may be an app playing digital silence); the wait doubles per rebuild…
    public var zeroTimeout: Double
    /// …up to this, and goes back to `zeroTimeout` once a non-zero sample arrives.
    public var zeroRetryMax: Double
    /// After the default output device changed, zeros for only this long are enough for one rebuild.
    public var zeroTimeoutAfterRouteChange: Double
    /// How long after the change the shorter wait applies. Sound that goes on arriving keeps the zeros short, so
    /// nothing is rebuilt; the window only ends the special case.
    public var routeChangeWindow: Double
    /// Zeros for this long despite a rebuild: the owner is told once (`SourceHealth.setNotArrivingObserver`).
    public var notArrivingAfter: Double
    /// How long one look waits for the answer about other processes; no answer counts as "nobody plays".
    public var probeTimeout: Duration

    public init(checkInterval: Duration = .milliseconds(250), stallTimeout: Double = 2, retryDelay: Double = 0.5,
                maxConsecutiveFailures: Int = 5, maxRebuilds: Int = 30, rebuildBudgetReset: Double = 60,
                zeroTimeout: Double = 5, zeroRetryMax: Double = 60, zeroTimeoutAfterRouteChange: Double = 2,
                routeChangeWindow: Double = 10, notArrivingAfter: Double = 60, probeTimeout: Duration = .seconds(1)) {
        self.checkInterval = checkInterval; self.stallTimeout = stallTimeout; self.retryDelay = retryDelay
        self.maxConsecutiveFailures = maxConsecutiveFailures; self.maxRebuilds = maxRebuilds
        self.rebuildBudgetReset = rebuildBudgetReset; self.zeroTimeout = zeroTimeout; self.zeroRetryMax = zeroRetryMax
        self.zeroTimeoutAfterRouteChange = zeroTimeoutAfterRouteChange; self.routeChangeWindow = routeChangeWindow
        self.notArrivingAfter = notArrivingAfter; self.probeTimeout = probeTimeout
    }

    public static let standard = SystemTapRecoveryPolicy()
}

/// IOProc counters; written only from the audio callback, read from anywhere.
private final class IOCounters: Sendable {
    let callbacks = Atomic<Int>(0)
    let frames = Atomic<Int>(0)
}

/// System audio (all processes except `excludeBundleIDs`) via a Core Audio process tap and a private aggregate device.
///
/// Every hardware call runs on a dedicated serial queue so neither the actor's executor nor the main thread blocks
/// (`AudioDeviceStart` can wait ~90 s on the permission dialog; teardown can block for minutes). Both waits are bounded:
/// `start` throws `.timedOut(call: "AudioDeviceStart")` after `startTimeout`, `stop` gives up after `stopTimeout`.
///
/// Recovery: a tap can keep calling back with nothing but zeros, or stop calling back, while other apps play audio
/// (seen on a real Mac: a whole meeting of exact zeros, and the app said nothing). Zeros alone prove nothing, though:
/// with nobody playing, a tap delivers zeros, or no callbacks at all before the first sound. So while running the
/// source asks a few times a second whether another process plays audio (`TapHardware.otherProcessIsPlayingAudio`)
/// and rebuilds — tear down, bring up, new ring and drain — only then:
/// - no callback for `stallTimeout`: rebuild with back-off, and after `maxConsecutiveFailures` in a row (or
///   `maxRebuilds`) stop rebuilding and report through `health` (`MicrophoneRecoveryPolicy`'s budget);
/// - only zeros for `zeroTimeout` (`zeroTimeoutAfterRouteChange` right after the default output device changed):
///   rebuild, wait twice as long before the next one (up to `zeroRetryMax`), never give up, not even when such a
///   rebuild leaves the tap down (it is then brought up again at the next wait).
/// Neither while the recording is paused (`SourceHealth.setPaused`).
/// Chunks keep their host-time stamps, so a rebuild's gap is silence on the track's timeline, not a shift.
public actor ProcessTapSource: AudioSource {
    public static let aggregateUIDPrefix = "com.yutaokoshi.autonote.tap."

    public nonisolated let track: Track = .system
    /// Counted by the drain and the watchdog: tells "callbacks stopped" from "zeros kept arriving", and both from
    /// plain silence (nobody was playing).
    public nonisolated var health: SourceHealth? { counts }
    private nonisolated let counts = SourceHealth()

    private struct Objects: @unchecked Sendable {   // AudioDeviceIOProcID is a C function pointer
        var tap: AudioObjectID
        var aggregate: AudioObjectID
        var proc: AudioDeviceIOProcID
    }

    private struct BringUp: @unchecked Sendable {
        var objects: Objects
        var ring: AudioRingBuffer
        var format: AudioStreamBasicDescription
    }

    private enum State {
        case idle
        case starting
        case running
    }

    /// Everything one bring-up made; replaced by a rebuild.
    private struct Pipeline {
        var objects: Objects
        var ring: AudioRingBuffer
        var drain: Task<Void, Never>
        var format: AudioStreamBasicDescription
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "ProcessTapSource")

    private let clock: MeetingClock
    private let hardware: any TapHardware
    private let excludeBundleIDs: [String]
    private let layout: AggregateLayout
    private let stopTimeout: Duration
    private let startTimeout: Duration
    private let policy: SystemTapRecoveryPolicy
    private let controlQueue = DispatchQueue(label: "com.yutaokoshi.autonote.tap.control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.yutaokoshi.autonote.tap.io", qos: .userInteractive)
    /// The "does another process play audio" reads; apart from `controlQueue`, which a teardown can block for long.
    private let probeQueue = DispatchQueue(label: "com.yutaokoshi.autonote.tap.probe", qos: .utility)

    private var state: State = .idle
    private var stopRequestedWhileStarting = false
    private var counters = IOCounters()
    /// Dropped frames of the rings already let go (rebuilds, the stop).
    private var retiredDropped = 0

    // While running. Times are seconds on the meeting timeline.
    private var pipeline: Pipeline?
    private var onBuffer: (@Sendable (AudioChunk) -> Void)?
    private var watchdog: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var lastRecords = 0
    private var lastCallbackAt = 0.0
    private var lastNonZeroCallbacks = 0
    private var lastNonZeroAt = 0.0
    /// Since when another process has been playing without a break; nil while nobody plays.
    private var othersPlayingSince: Double?
    /// When the current pipeline came up: nothing is expected from it before.
    private var pipelineSince = 0.0
    private var rebuilds = 0
    private var consecutiveFailures = 0
    /// Stall rebuilds counted against `maxRebuilds`; back to 0 after `rebuildBudgetReset` of flowing callbacks.
    private var rebuildsInBudget = 0
    private var healthySince: Double?
    private var nextStallRebuildAt = 0.0
    /// The wait before the next zero rebuild, and how many the current stretch of zeros has had.
    private var zeroWait = 0.0
    private var nextZeroRebuildAt = 0.0
    private var zeroRebuildsInStretch = 0
    /// The default output device as last seen, and when it was seen to change (until a rebuild or a non-zero sample).
    private var lastRoute: String?
    private var routeChangedAt: Double?
    /// The tap is down because a rebuild for zeros could not bring it up again.
    private var downAfterZeroRebuild = false
    private var gaveUp = false

    public init(clock: MeetingClock, hardware: any TapHardware = CoreAudioTapHardware(),
                excludeBundleIDs: [String] = [Bundle.main.bundleIdentifier].compactMap { $0 },
                layout: AggregateLayout = .tapOnly, stopTimeout: Duration = .seconds(5),
                startTimeout: Duration = .seconds(10), policy: SystemTapRecoveryPolicy = .standard) {
        self.clock = clock; self.hardware = hardware; self.excludeBundleIDs = excludeBundleIDs
        self.layout = layout; self.stopTimeout = stopTimeout; self.startTimeout = startTimeout
        self.policy = policy
    }

    /// Safety net when the owner drops a running source without `stop()`: no waiting, teardown runs in the background.
    deinit {
        watchdog?.cancel()
        if let pipeline {
            pipeline.drain.cancel()
            let hardware = self.hardware, objects = pipeline.objects
            controlQueue.async { Self.tearDown(hardware, objects) }
        }
    }

    /// Test hooks: rebuilds finished so far in this recording (nil while one is under way), and how many times the
    /// watchdog has looked.
    var finishedRebuilds: Int? { rebuildTask == nil ? rebuilds : nil }
    var watchdogLooks: Int { looks }
    private var looks = 0

    public static func aggregateDescription(tapUUID: String, layout: AggregateLayout, outputUID: String?) -> [String: any Sendable] {
        var d: [String: any Sendable] = [
            kAudioAggregateDeviceNameKey: "AutoNote System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true] as [String: any Sendable]],
        ]
        if layout == .withOutputClock, let outputUID {
            d[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            d[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID] as [String: any Sendable]]
        }
        return d
    }

    public func statistics() -> SourceStatistics {
        SourceStatistics(callbacks: counters.callbacks.load(ordering: .relaxed),
                         frames: counters.frames.load(ordering: .relaxed),
                         droppedFrames: retiredDropped + (pipeline?.ring.droppedFrames ?? 0))
    }

    public func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws {
        guard case .idle = state else { throw AudioSourceError.alreadyStarted }
        state = .starting
        stopRequestedWhileStarting = false
        counters = IOCounters()
        retiredDropped = 0

        // Bounded wait: `AudioDeviceStart` can block ~90 s while the permission dialog is unanswered. A bring-up that
        // finishes after the timeout is torn down on `controlQueue` at once; its objects are never used.
        guard let result = await bringUp(timeout: startTimeout) else {
            Self.logger.error("start timeout")
            state = .idle
            throw AudioSourceError.timedOut(call: "AudioDeviceStart")
        }
        let up: BringUp
        do {
            up = try result.get()
        } catch {
            state = .idle
            throw error
        }
        guard let made = makePipeline(up, onBuffer: onBuffer) else {
            state = .idle
            await teardown(up.objects)
            throw AudioSourceError.unsupportedFormat
        }
        pipeline = made
        self.onBuffer = onBuffer
        resetRecoveryState()
        state = .running
        watchdog = makeWatchdog()
        if stopRequestedWhileStarting { await stop() }
    }

    /// The watchdog and any rebuild end first; then the teardown (bounded wait), then the drain task empties the ring
    /// and flushes.
    public func stop() async {
        switch state {
        case .idle: return
        case .starting: stopRequestedWhileStarting = true; return
        case .running:
            state = .idle
            watchdog?.cancel(); watchdog = nil
            // A rebuild sees `.idle` after its next await and stops; a tap it had already brought up lands in
            // `pipeline`, so the lines below tear it down.
            if let rebuildTask { await rebuildTask.value }
            rebuildTask = nil
            if let old = pipeline {
                pipeline = nil
                await retire(old)
            }
            onBuffer = nil
            if rebuilds > 0 {
                Self.logger.notice("system tap stopped after \(self.rebuilds, privacy: .public) rebuild(s)\(self.gaveUp ? " (gave up)" : "", privacy: .public)")
            }
        }
    }

    // MARK: - Recovery

    private func resetRecoveryState() {
        let now = clock.now().seconds
        lastRecords = 0
        lastCallbackAt = now
        lastNonZeroCallbacks = counts.nonZeroCallbacks
        lastNonZeroAt = now
        othersPlayingSince = nil
        pipelineSince = now
        rebuilds = 0
        consecutiveFailures = 0
        rebuildsInBudget = 0
        healthySince = nil
        nextStallRebuildAt = now
        zeroWait = policy.zeroTimeout
        nextZeroRebuildAt = now
        zeroRebuildsInStretch = 0
        lastRoute = nil
        routeChangedAt = nil
        downAfterZeroRebuild = false
        gaveUp = false
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

    /// One look at the tap. Decides whether a rebuild is due; never runs two rebuilds at once. After a give-up it
    /// only keeps recording whether another process plays, so the manifest still counts the seconds that went missing.
    private func check() async {
        guard case .running = state, rebuildTask == nil else { return }
        let hardware = self.hardware, exclude = excludeBundleIDs, knownRoute = lastRoute
        // Every hardware call stays off the actor, the route's description (read only when the route changed) too.
        let answer: (playing: Bool?, route: String?, description: String?)? = await probeQueue.runAwaiting(timeout: policy.probeTimeout, {
            let route = hardware.outputRouteToken()
            let changed = if let route, let knownRoute { route != knownRoute } else { false }
            return (hardware.otherProcessIsPlayingAudio(excludingBundleIDs: exclude), route, changed ? hardware.routeDescription() : nil)
        }, abandoned: { _ in })
        // `stop()` may have run while this look waited on the probe queue.
        guard case .running = state, rebuildTask == nil else { return }
        defer { looks += 1 }
        let now = clock.now().seconds
        // Unknown (no answer in time, or the system does not tell) counts as "nobody plays": never a reason to rebuild.
        let playing = answer?.playing == true
        counts.recordOutputPoll(at: now, othersPlaying: playing)
        if gaveUp {
            // The last tap stayed up. Sound on it means the track is being recorded after all: the failure is taken
            // back and the watch goes on with a fresh budget.
            guard pipeline != nil, counts.nonZeroCallbacks != lastNonZeroCallbacks else { return }
            gaveUp = false
            consecutiveFailures = 0; rebuildsInBudget = 0; healthySince = now
            lastCallbackAt = now; nextStallRebuildAt = now
            Self.logger.notice("system audio is heard again on the tap that was given up on: recording it")
            counts.reportRecovered()
        }
        if let at = routeChangedAt, now - at > policy.routeChangeWindow { routeChangedAt = nil }
        if let route = answer?.route {
            if let last = lastRoute, last != route {
                // The usual moment for a tap to go deaf: zeros get a shorter wait once, and the back-off starts over.
                // Zeros that were already going on wait the shorter time too, so the new output can settle.
                Self.logger.notice("system tap: default output device changed \(answer?.description ?? "", privacy: .public)")
                routeChangedAt = now
                zeroWait = policy.zeroTimeout
                nextZeroRebuildAt = now + policy.zeroTimeoutAfterRouteChange
            }
            lastRoute = route
        }

        let records = pipeline?.ring.recordsWritten ?? 0
        if records != lastRecords {
            lastRecords = records
            lastCallbackAt = now
            if consecutiveFailures > 0 {
                Self.logger.notice("system tap callbacks are back after rebuild")
            }
            consecutiveFailures = 0
            let since = healthySince ?? now
            healthySince = since
            if rebuildsInBudget > 0, now - since >= policy.rebuildBudgetReset {
                Self.logger.notice("system tap ran \(Self.seconds(now - since), privacy: .public) s without a rebuild: rebuild budget reset (\(self.rebuildsInBudget, privacy: .public) used)")
                rebuildsInBudget = 0
            }
        }
        let nonZero = counts.nonZeroCallbacks
        if nonZero != lastNonZeroCallbacks {
            lastNonZeroCallbacks = nonZero
            lastNonZeroAt = now
            if zeroRebuildsInStretch > 0 {
                Self.logger.notice("system audio is non-zero again after \(self.zeroRebuildsInStretch, privacy: .public) rebuild(s) for zeros")
            }
            zeroRebuildsInStretch = 0
            zeroWait = policy.zeroTimeout
            nextZeroRebuildAt = now
            // `routeChangedAt` stays: the sample may be from just before the change (the look that sees the change
            // usually sees it too). It ends with the first rebuild or after `routeChangeWindow`.
            counts.reportArrivingAgain()
        }

        // A tap that could not be brought up again is down, whoever plays.
        if pipeline == nil {
            if downAfterZeroRebuild {
                // It was delivering until a rebuild for zeros took it down, and those zeros may have been plain
                // silence: bring it up again at the next zero wait, outside the budget and without ever giving up.
                // Meanwhile nothing of the track is recorded, which is told like zeros that do not end.
                let silent = now - max(lastNonZeroAt, othersPlayingSince ?? now)
                if playing, !counts.isPaused, silent >= policy.notArrivingAfter { counts.reportNotArriving(seconds: Int(silent)) }
                guard now >= nextZeroRebuildAt else { return }
                rebuildTask = Task { await self.rebuild(reason: "tap is down after a rebuild for zeros", stall: false) }
                return
            }
            await rebuildForStall(reason: "tap is not running", now: now)
            return
        }
        // A paused recording writes nothing, so nothing can be missing: like nobody playing, and the waits start
        // over at the resume.
        guard playing, !counts.isPaused else {
            othersPlayingSince = nil
            return
        }
        let playingSince = othersPlayingSince ?? now
        othersPlayingSince = playingSince

        // Nothing is expected before somebody plays, nor before this tap came up.
        let quiet = now - max(lastCallbackAt, playingSince, pipelineSince)
        if quiet >= policy.stallTimeout {
            await rebuildForStall(reason: "no callbacks for \(Self.seconds(quiet)) s while another process plays audio", now: now)
            return
        }
        // Zeros are judged only on a tap that calls back; one that does not is the stall's business above.
        let zeros = now - max(lastNonZeroAt, playingSince)
        let early = routeChangedAt.map { min(zeros, now - $0) >= policy.zeroTimeoutAfterRouteChange } ?? false
        guard lastRecords > 0, zeros >= policy.zeroTimeout || early else { return }
        if zeroRebuildsInStretch > 0, zeros >= policy.notArrivingAfter {
            counts.reportNotArriving(seconds: Int(zeros))   // once per stretch of zeros
        }
        guard now >= nextZeroRebuildAt else { return }
        routeChangedAt = nil
        let reason = "only zero samples for \(Self.seconds(zeros)) s while another process plays audio\(early ? ", after the output device changed" : "")"
        rebuildTask = Task { await self.rebuild(reason: reason, stall: false) }
    }

    private func rebuildForStall(reason: String, now: Double) async {
        guard now >= nextStallRebuildAt else { return }
        if consecutiveFailures >= policy.maxConsecutiveFailures || rebuildsInBudget >= policy.maxRebuilds {
            await giveUp(reason: reason)
            return
        }
        rebuildTask = Task { await self.rebuild(reason: reason, stall: true) }
    }

    /// Tear down → bring up → new ring, converter and drain. `stall`: counted against the give-up budget.
    private func rebuild(reason: String, stall: Bool) async {
        defer { rebuildTask = nil }
        rebuilds += 1
        let attempt = rebuilds
        var backoff = 0.0
        if stall {
            rebuildsInBudget += 1
            consecutiveFailures += 1
            healthySince = nil
            // Exponential back-off for the next attempt if this one brings no callback.
            backoff = policy.retryDelay * Double(1 << min(consecutiveFailures - 1, 6))
        } else {
            zeroRebuildsInStretch += 1
        }
        counts.noteRestart()
        let hardware = self.hardware
        let route = await probeQueue.runAwaiting(timeout: policy.probeTimeout, { hardware.routeDescription() }, abandoned: { _ in }) ?? ""
        Self.logger.notice("system tap rebuild #\(attempt, privacy: .public) (\(reason, privacy: .public)) \(route, privacy: .public)")

        if let old = pipeline {
            pipeline = nil
            await retire(old)       // the old ring's tail is emitted at its own timeline position
        }
        guard case .running = state, let onBuffer else { return }

        // A bring-up that outlives the wait is torn down on the control queue by itself.
        let result = await bringUp(timeout: stopTimeout)
        // If `stop()` arrived meanwhile, it waits for this task and then retires `pipeline`; so a tap that came up
        // still gets its pipeline here, or nobody would tear it down.
        let stopping: Bool = if case .running = state { false } else { true }
        let after = clock.now().seconds
        guard let result else {
            if !stopping { fail(attempt, AudioSourceError.timedOut(call: "AudioDeviceStart"), stall: stall, backoff: backoff, now: after) }
            return
        }
        switch result {
        case .failure(let error):
            if !stopping { fail(attempt, error, stall: stall, backoff: backoff, now: after) }
        case .success(let up):
            guard let made = makePipeline(up, onBuffer: onBuffer) else {
                await teardown(up.objects)
                if !stopping { fail(attempt, AudioSourceError.unsupportedFormat, stall: stall, backoff: backoff, now: after) }
                return
            }
            pipeline = made
            downAfterZeroRebuild = false
            lastRecords = 0
            lastCallbackAt = after
            pipelineSince = after
            if stall {
                nextStallRebuildAt = after + backoff
            } else {
                zeroWait = min(zeroWait * 2, policy.zeroRetryMax)
                nextZeroRebuildAt = after + zeroWait
            }
            Self.logger.notice("system tap rebuild #\(attempt, privacy: .public) restarted the tap (\(Int(up.format.mSampleRate.rounded()), privacy: .public) Hz \(Int(up.format.mChannelsPerFrame), privacy: .public) ch)")
        }
    }

    /// `stall` false: the rebuild was for zeros, on a tap that was calling back. Its failure never counts towards
    /// giving up (see `check()`); the tap is brought up again after the next zero wait.
    private func fail(_ attempt: Int, _ error: any Error, stall: Bool, backoff: Double, now: Double) {
        if stall {
            nextStallRebuildAt = now + max(backoff, policy.retryDelay)
        } else {
            downAfterZeroRebuild = true
            zeroWait = min(zeroWait * 2, policy.zeroRetryMax)
            nextZeroRebuildAt = now + zeroWait
        }
        Self.logger.error("system tap rebuild #\(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    /// Stops rebuilding and tells the owner. The last tap stays up until `stop()`: should the system start calling it
    /// again, that audio is still recorded, and non-zero samples on it take the failure back (`check()`).
    private func giveUp(reason: String) async {
        guard case .running = state, !gaveUp else { return }
        gaveUp = true
        let message = "system audio stopped arriving and \(rebuilds) rebuild(s) did not bring it back (\(reason))"
        Self.logger.error("system tap gave up after \(self.rebuilds, privacy: .public) rebuild(s): \(reason, privacy: .public)")
        counts.reportFailure(message)
    }

    /// Teardown (bounded wait), then the drain empties the ring and flushes; the ring's dropped frames are kept.
    private func retire(_ old: Pipeline) async {
        await teardown(old.objects)
        old.drain.cancel()
        await old.drain.value
        let dropped = old.ring.droppedFrames
        retiredDropped += dropped
        counts.addDroppedFrames(dropped)
    }

    private func makePipeline(_ up: BringUp, onBuffer: @Sendable @escaping (AudioChunk) -> Void) -> Pipeline? {
        guard let converter = try? SampleConverter(inputSampleRate: up.format.mSampleRate,
                                                   inputChannels: Int(up.format.mChannelsPerFrame)) else { return nil }
        let drain = SourceDrain.makeTask(track: track, ring: up.ring, converter: converter, inputRate: up.format.mSampleRate,
                                         clock: clock, health: counts, onBuffer: onBuffer)
        return Pipeline(objects: up.objects, ring: up.ring, drain: drain, format: up.format)
    }

    /// Runs the bring-up on `controlQueue`, waiting at most `timeout`; nil when the wait timed out (the late bring-up
    /// is then torn down on the queue at once and its objects are never used).
    private func bringUp(timeout: Duration) async -> Result<BringUp, any Error>? {
        let hardware = self.hardware, layout = self.layout, ioQueue = self.ioQueue, counters = self.counters
        let spec = TapSpec(excludeBundleIDs: excludeBundleIDs)
        return await controlQueue.runAwaiting(timeout: timeout, {
            Result { try Self.bringUp(hardware, spec: spec, layout: layout, ioQueue: ioQueue, counters: counters) }
        }, abandoned: { late in
            if case .success(let up) = late { Self.tearDown(hardware, up.objects) }
        })
    }

    private static func seconds(_ s: Double) -> String { String(format: "%.1f", s) }

    // MARK: - Hardware sequences (run on `controlQueue`)

    /// createTap → tapFormat → (defaultOutputDeviceUID) → createAggregate → createIOProc → start.
    /// On failure, destroys what was created (reverse order) and rethrows.
    private nonisolated static func bringUp(_ hw: any TapHardware, spec: TapSpec, layout: AggregateLayout,
                                            ioQueue: DispatchQueue, counters: IOCounters) throws -> BringUp {
        let tap = try hw.createTap(spec)
        var aggregate: AudioObjectID?
        var proc: AudioDeviceIOProcID?
        do {
            let format = try hw.tapFormat(tap.id)
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
                throw AudioSourceError.unsupportedFormat
            }
            let outputUID = layout == .withOutputClock ? try hw.defaultOutputDeviceUID() : nil
            let agg = try hw.createAggregate(aggregateDescription(tapUUID: tap.uuid, layout: layout, outputUID: outputUID))
            aggregate = agg
            let channels = Int(format.mChannelsPerFrame)
            let ring = AudioRingBuffer(channels: channels, capacityFrames: Int(format.mSampleRate * 10), recordCapacity: 4096)
            let p = try hw.createIOProc(agg, queue: ioQueue, block: makeIOBlock(ring: ring, counters: counters, channels: channels))
            proc = p
            try hw.start(agg, p)
            logger.notice("system tap and aggregate created (\(Int(format.mSampleRate.rounded()), privacy: .public) Hz \(channels, privacy: .public) ch, layout: \(layout == .tapOnly ? "tapOnly" : "withOutputClock", privacy: .public)) \(hw.routeDescription(), privacy: .public)")
            return BringUp(objects: Objects(tap: tap.id, aggregate: agg, proc: p), ring: ring, format: format)
        } catch {
            if let aggregate, let proc { logFailure { try hw.destroyIOProc(aggregate, proc) } }
            if let aggregate { logFailure { try hw.destroyAggregate(aggregate) } }
            logFailure { try hw.destroyTap(tap.id) }
            throw error
        }
    }

    /// stop → destroyIOProc → destroyAggregate → destroyTap; every step runs even if an earlier one fails.
    private nonisolated static func tearDown(_ hw: any TapHardware, _ o: Objects) {
        logFailure { try hw.stop(o.aggregate, o.proc) }
        logFailure { try hw.destroyIOProc(o.aggregate, o.proc) }
        logFailure { try hw.destroyAggregate(o.aggregate) }
        logFailure { try hw.destroyTap(o.tap) }
        logger.notice("system tap and aggregate destroyed \(hw.routeDescription(), privacy: .public)")
    }

    private nonisolated static func logFailure(_ body: () throws -> Void) {
        do { try body() } catch { logger.error("teardown step failed: \(String(describing: error), privacy: .public)") }
    }

    /// Runs the teardown on `controlQueue`; gives up waiting after `stopTimeout` (the teardown keeps going).
    private func teardown(_ objects: Objects) async {
        let hardware = self.hardware
        let finished = await controlQueue.runAwaiting(timeout: stopTimeout) { Self.tearDown(hardware, objects) }
        if !finished { Self.logger.error("teardown timeout") }
    }

    // MARK: - Real-time and drain

    /// The IOProc body: count, then copy into the ring. No locks, allocation, logging or I/O.
    private nonisolated static func makeIOBlock(ring: AudioRingBuffer, counters: IOCounters, channels: Int) -> AudioDeviceIOBlock {
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        return { _, inInputData, inInputTime, _, _ in
            let abl = inInputData
            counters.callbacks.add(1, ordering: .relaxed)   // every invocation, even an empty one
            guard abl.pointee.mNumberBuffers > 0 else { return }
            let first = abl.pointee.mBuffers
            // Interleaved: one buffer holds all channels; planar: each buffer holds one channel.
            let frameBytes = Int(first.mNumberChannels) == channels ? bytesPerFrame : MemoryLayout<Float>.size
            let frames = Int(first.mDataByteSize) / frameBytes
            guard frames > 0 else { return }
            counters.frames.add(frames, ordering: .relaxed)
            ring.write(abl, frameCount: frames, hostTime: inInputTime.pointee.mHostTime, sampleTime: inInputTime.pointee.mSampleTime)
        }
    }
}
