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

/// Applies manifest changes one after another: each enqueued update waits for every earlier one, so updates run in
/// the order `enqueue` is called (the session calls it synchronously on its actor, so its call order is kept).
final class ManifestSaver: Sendable {
    private let store: ManifestStore
    private let id: MeetingID
    private let tail = Mutex<Task<Void, Never>?>(nil)
    private let lastSaved: Mutex<Manifest>

    init(store: ManifestStore, initial: Manifest) {
        self.store = store; self.id = initial.id; self.lastSaved = Mutex(initial)
    }

    /// The manifest as of the last successful update.
    var latest: Manifest { lastSaved.withLock { $0 } }

    /// Queues `ManifestStore.update` of `body` behind the previous update; the task yields the saved manifest.
    func enqueue(_ body: @escaping @Sendable (inout Manifest) -> Void) -> Task<Result<Manifest, any Error>, Never> {
        let store = self.store, id = self.id
        return tail.withLock { tail in
            let previous = tail
            let save = Task { [self] () -> Result<Manifest, any Error> in
                await previous?.value
                do {
                    let saved = try await store.update(id, body)
                    lastSaved.withLock { $0 = saved }
                    return .success(saved)
                } catch {
                    return .failure(error)
                }
            }
            tail = Task { _ = await save.value }
            return save
        }
    }

    /// Waits for every update enqueued so far.
    func flush() async {
        await tail.withLock { $0 }?.value
    }
}

/// FIFO admission for the session's public operations. Owned by the actor; `wait` parks a caller and `leave` hands
/// ownership straight to the next one.
struct OperationGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// True when the caller may proceed now; otherwise it must `wait`.
    mutating func tryEnter() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    mutating func wait(_ continuation: CheckedContinuation<Void, Never>) { waiters.append(continuation) }

    mutating func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

extension TrackStatistics {
    mutating func add(_ chunk: AudioChunk) {
        chunks += 1
        samples += chunk.samples.count
        peakDBFS = max(peakDBFS, AudioLevel.peakDBFS(chunk.samples))
    }
}

/// The two tracks' segment writers. A track whose writer failed once is marked and takes no more chunks.
struct TrackWriters {
    private static let tracks: [Track] = [.mic, .system]
    private var writers: [Track: WAVSegmentWriter] = [:]
    private var failed: Set<Track> = []

    init() {}

    init(meetingDirectory: URL) {
        for track in Self.tracks { writers[track] = WAVSegmentWriter(track: track, meetingDirectory: meetingDirectory) }
    }

    func accepts(_ track: Track) -> Bool { !failed.contains(track) && writers[track]?.isOpen == true }

    mutating func write(_ chunk: AudioChunk, to track: Track) throws -> [SegmentChange] {
        guard writers[track] != nil else { throw WAVSegmentWriterError.notOpen }
        return try writers[track]!.write(chunk)
    }

    /// Applies `body` to each writer; a failing writer does not keep the other from transitioning.
    mutating func transition(skippingFailed: Bool = false, _ body: (inout WAVSegmentWriter) throws -> [SegmentChange])
        -> (changes: [SegmentChange], failures: [(Track, any Error)]) {
        var changes: [SegmentChange] = []
        var failures: [(Track, any Error)] = []
        for track in Self.tracks where writers[track] != nil && !(skippingFailed && failed.contains(track)) {
            do { changes += try body(&writers[track]!) } catch { failures.append((track, error)) }
        }
        return (changes, failures)
    }

    /// True the first time `track` is marked.
    mutating func markFailed(_ track: Track) -> Bool { failed.insert(track).inserted }
}
