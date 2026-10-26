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

/// IOProc counters; written only from the audio callback, read from anywhere.
private final class IOCounters: Sendable {
    let callbacks = Atomic<Int>(0)
    let frames = Atomic<Int>(0)
}

/// System audio (all processes except `excludeBundleIDs`) via a Core Audio process tap and a private aggregate device.
///
/// Every hardware call runs on a dedicated serial queue so neither the actor's executor nor the main thread blocks
/// (`AudioDeviceStart` can wait ~90 s on the permission dialog; teardown can block for minutes).
public actor ProcessTapSource: AudioSource {
    public static let aggregateUIDPrefix = "com.yutaokoshi.autonote.tap."

    public nonisolated let track: Track = .system

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
        case running(objects: Objects, ring: AudioRingBuffer, drain: Task<Void, Never>)
    }

    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "ProcessTapSource")

    private let clock: MeetingClock
    private let hardware: any TapHardware
    private let excludeBundleIDs: [String]
    private let layout: AggregateLayout
    private let stopTimeout: Duration
    private let controlQueue = DispatchQueue(label: "com.yutaokoshi.autonote.tap.control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.yutaokoshi.autonote.tap.io", qos: .userInteractive)

    private var state: State = .idle
    private var stopRequestedWhileStarting = false
    private var counters = IOCounters()
    private var droppedAtStop = 0

    public init(clock: MeetingClock, hardware: any TapHardware = CoreAudioTapHardware(),
                excludeBundleIDs: [String] = [Bundle.main.bundleIdentifier].compactMap { $0 },
                layout: AggregateLayout = .tapOnly, stopTimeout: Duration = .seconds(5)) {
        self.clock = clock; self.hardware = hardware; self.excludeBundleIDs = excludeBundleIDs
        self.layout = layout; self.stopTimeout = stopTimeout
    }

    /// Safety net when the owner drops a running source without `stop()`: no waiting, teardown runs in the background.
    deinit {
        if case .running(let objects, _, let drain) = state {
            drain.cancel()
            let hardware = self.hardware
            controlQueue.async { Self.tearDown(hardware, objects) }
        }
    }

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
        let dropped: Int
        if case .running(_, let ring, _) = state { dropped = ring.droppedFrames } else { dropped = droppedAtStop }
        return SourceStatistics(callbacks: counters.callbacks.load(ordering: .relaxed),
                                frames: counters.frames.load(ordering: .relaxed), droppedFrames: dropped)
    }

    public func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws {
        guard case .idle = state else { throw AudioSourceError.alreadyStarted }
        state = .starting
        stopRequestedWhileStarting = false
        let counters = IOCounters()
        self.counters = counters
        droppedAtStop = 0

        let hardware = self.hardware, layout = self.layout, ioQueue = self.ioQueue
        let spec = TapSpec(excludeBundleIDs: excludeBundleIDs)
        let result: Result<BringUp, any Error> = await withCheckedContinuation { cont in
            controlQueue.async {
                cont.resume(returning: Result { try Self.bringUp(hardware, spec: spec, layout: layout, ioQueue: ioQueue, counters: counters) })
            }
        }
        let up: BringUp
        do {
            up = try result.get()
        } catch {
            state = .idle
            throw error
        }
        guard let converter = try? SampleConverter(inputSampleRate: up.format.mSampleRate, inputChannels: Int(up.format.mChannelsPerFrame)) else {
            state = .idle
            await teardown(up.objects)
            throw AudioSourceError.unsupportedFormat
        }
        let drain = SourceDrain.makeTask(track: track, ring: up.ring, converter: converter, inputRate: up.format.mSampleRate,
                                          clock: clock, onBuffer: onBuffer)
        state = .running(objects: up.objects, ring: up.ring, drain: drain)
        if stopRequestedWhileStarting { await stop() }
    }

    public func stop() async {
        switch state {
        case .idle: return
        case .starting: stopRequestedWhileStarting = true; return
        case .running(let objects, let ring, let drain):
            state = .idle
            await teardown(objects)
            drain.cancel()
            await drain.value
            droppedAtStop = ring.droppedFrames
        }
    }

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
