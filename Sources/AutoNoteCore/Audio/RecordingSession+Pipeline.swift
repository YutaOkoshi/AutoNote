import Foundation

/// The chunk consumer: one task per meeting reads the `ChunkQueue` in arrival order and, per chunk, feeds the silence
/// monitor, writes the track (unless paused or the track's writer failed), forwards to `audio(for:)` and saves any
/// segment change. `waitUntilIdle` counts a chunk as handled only after all of that, including the save.
extension RecordingSession {
    /// Returns once every chunk accepted so far has been handled (written, forwarded, its manifest change saved).
    func waitUntilIdle() async {
        guard let queue else { return }
        let target = queue.enqueued
        guard processed < target else { return }
        await withCheckedContinuation { idleWaiters.append((target, $0)) }
    }

    func consume(_ stream: AsyncStream<ChunkQueue.Element>) async {
        for await (track, chunk) in stream {
            await handle(chunk, from: track)
            processed += 1
            resumeIdleWaiters()
        }
        resumeIdleWaiters(all: true)
    }

    func handle(_ incoming: AudioChunk, from track: Track) async {
        var chunk = incoming
        chunk.track = track
        monitor?.observe(track, chunk: chunk)
        if case .paused = state { return }
        guard writers.accepts(track) else { return }
        let changes: [SegmentChange]
        do {
            changes = try writers.write(chunk, to: track)
        } catch {
            await reportWriterFailures([(track, error)])
            return
        }
        stats[track, default: TrackStatistics()].add(chunk)
        audioSubscribers[track]?.continuation.yield(chunk)
        guard !changes.isEmpty else { return }
        do { try await persist { $0.apply(changes) } } catch { Self.log("segment save", error) }
    }

    /// Finishes the queue and waits until the consumer has handled everything in it.
    func drainPipeline() async {
        queue?.finish()
        await consumer?.value
    }

    func resumeIdleWaiters(all: Bool = false) {
        let ready = idleWaiters.filter { all || $0.target <= processed }
        idleWaiters.removeAll { all || $0.target <= processed }
        for waiter in ready { waiter.continuation.resume() }
    }
}
