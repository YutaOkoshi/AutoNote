import Foundation
import Synchronization

/// Hand-off from the sources' `onBuffer` to the session's single consumer task. `onBuffer` only yields into the
/// stream and bumps a lock-free counter, so no actor hop or task is created per chunk and arrival order is kept.
final class ChunkQueue: Sendable {
    typealias Element = (Track, AudioChunk)

    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let enqueuedCount = Atomic<Int>(0)

    init() {
        (stream, continuation) = AsyncStream<Element>.makeStream()
    }

    /// Chunks accepted so far (yields after `finish` are not counted).
    var enqueued: Int { enqueuedCount.load(ordering: .acquiring) }

    func onBuffer(for track: Track) -> @Sendable (AudioChunk) -> Void {
        { [self] chunk in
            if case .enqueued = continuation.yield((track, chunk)) {
                enqueuedCount.add(1, ordering: .releasing)
            }
        }
    }

    /// The consumer drains what is buffered, then its loop ends.
    func finish() { continuation.finish() }
}

extension Manifest {
    /// `opened` adds the file (once); `closed` replaces the entry with the same `relativePath`.
    mutating func apply(_ changes: [SegmentChange]) {
        for change in changes {
            switch change {
            case .opened(let file):
                if !tracks.contains(where: { $0.relativePath == file.relativePath }) { tracks.append(file) }
            case .closed(let file):
                if let i = tracks.firstIndex(where: { $0.relativePath == file.relativePath }) {
                    tracks[i] = file
                } else {
                    tracks.append(file)
                }
            }
        }
    }
}

/// Applies manifest changes strictly in call order: each `update` waits for every earlier one, so concurrent callers
/// (the chunk consumer, `pause`, `bookmark`, …) never reorder `opened`/`closed` or pause edits on disk.
final class ManifestSaver: Sendable {
    private let store: ManifestStore
    private let id: MeetingID
    private let tail = Mutex<Task<Void, Never>?>(nil)

    init(store: ManifestStore, id: MeetingID) { self.store = store; self.id = id }

    /// `ManifestStore.update` of `body`, run after the previous update; returns the saved manifest.
    func update(_ body: @escaping @Sendable (inout Manifest) -> Void) async throws -> Manifest {
        let store = self.store, id = self.id
        let save = tail.withLock { tail -> Task<Result<Manifest, any Error>, Never> in
            let previous = tail
            let save = Task { () -> Result<Manifest, any Error> in
                await previous?.value
                do { return .success(try await store.update(id, body)) } catch { return .failure(error) }
            }
            tail = Task { _ = await save.value }
            return save
        }
        return try await save.value.get()
    }

    /// Waits for every update requested so far.
    func flush() async {
        await tail.withLock { $0 }?.value
    }
}

extension TrackStatistics {
    mutating func add(_ chunk: AudioChunk) {
        chunks += 1
        samples += chunk.samples.count
        peakDBFS = max(peakDBFS, AudioLevel.peakDBFS(chunk.samples))
    }
}
