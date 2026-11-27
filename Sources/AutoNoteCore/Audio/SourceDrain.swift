import Foundation
import Synchronization
import os

/// Resumes a checked continuation at most once, whichever of work completion and timeout comes first.
/// The winner is recorded under the same lock as the resume, so `timedOut` is final once the continuation resumes.
final class ResumeGate: Sendable {
    private enum State { case waiting(CheckedContinuation<Void, Never>?), resumed(timedOut: Bool) }
    private let state = Mutex<State>(.waiting(nil))

    /// Stores the continuation, or resumes it at once if `fire` already ran.
    func install(_ c: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { s -> Bool in
            if case .resumed = s { return true }
            s = .waiting(c); return false
        }
        if resumeNow { c.resume() }
    }

    /// Records the outcome and resumes the continuation. Returns true only for the first caller.
    @discardableResult
    func fire(timedOut: Bool) -> Bool {
        let (first, c) = state.withLock { s -> (Bool, CheckedContinuation<Void, Never>?) in
            guard case .waiting(let c) = s else { return (false, nil) }
            s = .resumed(timedOut: timedOut)
            return (true, c)
        }
        c?.resume()
        return first
    }

    /// True when the timeout side fired first; false while waiting or when the work finished first.
    var timedOut: Bool {
        state.withLock { s in
            if case .resumed(let timedOut) = s { return timedOut }
            return false
        }
    }
}

extension DispatchQueue {
    /// Runs `work` on this queue and waits for it, giving up after `timeout` (the work keeps going).
    /// Returns false when the wait timed out.
    @discardableResult
    func runAwaiting(timeout: Duration, _ work: @Sendable @escaping () -> Void) async -> Bool {
        await runAwaiting(timeout: timeout, work, abandoned: { _ in }) != nil
    }

    /// Runs `work` on this queue and waits for its value, giving up after `timeout` (the work keeps going).
    /// Returns nil when the wait timed out; the late value is then handed to `abandoned`, still on this queue,
    /// right after `work` returns. Exactly one of the caller and `abandoned` receives the value.
    func runAwaiting<T: Sendable>(timeout: Duration, _ work: @Sendable @escaping () -> T,
                                  abandoned: @Sendable @escaping (T) -> Void) async -> T? {
        let gate = ResumeGate()
        let box = Mutex<T?>(nil)
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            gate.fire(timedOut: true)
        }
        await withCheckedContinuation { cont in
            gate.install(cont)
            self.async {
                let value = work()
                box.withLock { $0 = value }
                if !gate.fire(timedOut: false) { abandoned(value) }
            }
        }
        timer.cancel()
        return gate.timedOut ? nil : box.withLock { $0 }
    }
}

enum SourceDrain {
    static let healthLogger = Logger(subsystem: "com.yutaokoshi.autonote", category: "AudioHealth")
    /// Seconds of meeting time per debug line with the callback count of the track.
    static let healthWindowSeconds = 10.0

    /// Every 20 ms: read all records, convert each to a chunk stamped with its own host time.
    /// When a record does not start where the previous one ended (within `TimelineAligner.tolerance`), emits the
    /// converter's tail at the end of the previous record and resets the converter.
    /// On cancellation, drains what is left and emits the converter's tail, placed at the end of the last record.
    static func makeTask(track: Track, ring: AudioRingBuffer, converter: sending SampleConverter, inputRate: Double,
                         clock: MeetingClock, health: SourceHealth? = nil,
                         onBuffer: @Sendable @escaping (AudioChunk) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var converter = converter
            var buffer: [Float] = []
            var expectedNext: Double?           // timeline seconds where the next record should start
            var lastHostTime: UInt64 = 0
            var window = (clock.now().seconds / healthWindowSeconds).rounded(.down)

            /// Diagnostics only: one debug line per 10 s of meeting time, even when no callback came at all; and one
            /// notice line when the track's state changed (normal ↔ all zero ↔ no callbacks), which is what a later
            /// look at the log needs and what a default log capture keeps.
            func logWindow() {
                guard let health else { return }
                let current = (clock.now().seconds / healthWindowSeconds).rounded(.down)
                guard current > window else { return }
                window = current
                let w = health.closeWindow()
                healthLogger.debug("\(track.rawValue, privacy: .public): last \(Int(healthWindowSeconds), privacy: .public) s callbacks=\(w.callbacks, privacy: .public) all_zero=\(w.state == .allZero, privacy: .public)")
                if let before = w.changedFrom {
                    healthLogger.notice("\(track.rawValue, privacy: .public): \(before.rawValue, privacy: .public) -> \(w.state.rawValue, privacy: .public) at \(Int(current * healthWindowSeconds), privacy: .public) s (callbacks=\(w.callbacks, privacy: .public) in the last \(Int(healthWindowSeconds), privacy: .public) s)")
                }
            }

            func drainAvailable() {
                while let record = ring.read(into: &buffer) {
                    let start = clock.timeline(hostTime: record.hostTime)
                    if let expected = expectedNext, abs(start.seconds - expected) > TimelineAligner.tolerance {
                        // Emit the pre-gap samples still buffered in the resampler, then start fresh.
                        let tail = converter.flush()
                        if !tail.isEmpty {
                            onBuffer(AudioChunk(track: track, samples: tail, start: TimelineTime(seconds: expected), hostTime: lastHostTime))
                        }
                        converter.reset()
                    }
                    expectedNext = start.seconds + Double(record.frameCount) / inputRate
                    lastHostTime = record.hostTime
                    if let health {
                        health.recordCallback(start: start.seconds, duration: Double(record.frameCount) / inputRate,
                                              nonZero: buffer.contains { $0 != 0 })
                    }
                    let samples = converter.convert(buffer)
                    if !samples.isEmpty {
                        onBuffer(AudioChunk(track: track, samples: samples, start: start, hostTime: record.hostTime))
                    }
                }
            }

            while !Task.isCancelled {
                drainAvailable()
                logWindow()
                try? await Task.sleep(for: .milliseconds(20))
            }
            drainAvailable()
            let tail = converter.flush()
            if !tail.isEmpty, let end = expectedNext {
                onBuffer(AudioChunk(track: track, samples: tail, start: TimelineTime(seconds: end), hostTime: lastHostTime))
            }
        }
    }
}
