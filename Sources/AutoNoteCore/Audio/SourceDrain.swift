import Foundation
import Synchronization

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
    /// Every 20 ms: read all records, convert each to a chunk stamped with its own host time.
    /// When a record does not start where the previous one ended (within `TimelineAligner.tolerance`), emits the
    /// converter's tail at the end of the previous record and resets the converter.
    /// On cancellation, drains what is left and emits the converter's tail, placed at the end of the last record.
    static func makeTask(track: Track, ring: AudioRingBuffer, converter: sending SampleConverter, inputRate: Double,
                         clock: MeetingClock, onBuffer: @Sendable @escaping (AudioChunk) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var converter = converter
            var buffer: [Float] = []
            var expectedNext: Double?           // timeline seconds where the next record should start
            var lastHostTime: UInt64 = 0

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
                    let samples = converter.convert(buffer)
                    if !samples.isEmpty {
                        onBuffer(AudioChunk(track: track, samples: samples, start: start, hostTime: record.hostTime))
                    }
                }
            }

            while !Task.isCancelled {
                drainAvailable()
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
