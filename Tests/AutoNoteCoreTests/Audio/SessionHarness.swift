import Foundation
import Synchronization
@testable import AutoNoteCore
import AutoNoteTestSupport

/// A `RecordingSession` wired to fakes: temporary `AppPaths`, `FakeAudioSourceFactory`, `FakeHostClock`, fixed `now`.
struct SessionHarness {
    let session: RecordingSession
    let manifests: ManifestStore
    let paths: AppPaths
    let factory: FakeAudioSourceFactory
    let mic: FakeAudioSource
    let system: FakeAudioSource
    let clock: FakeHostClock
    let disk: FakeDiskSpace

    static func make(disk: FakeDiskSpace = FakeDiskSpace(),
                     mic: FakeAudioSource = FakeAudioSource(track: .mic),
                     system: FakeAudioSource = FakeAudioSource(track: .system),
                     tickInterval: Duration = .seconds(3600)) async throws -> SessionHarness {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let manifests = ManifestStore(paths: paths)
        let factory = FakeAudioSourceFactory(mic: mic, system: system)
        let clock = FakeHostClock()
        // By default the production tick task is kept out of the way; tests drive `tick()` themselves.
        let session = RecordingSession(paths: paths, manifests: manifests, sources: factory, host: clock, disk: disk,
                                       now: { Samples.start }, tickInterval: tickInterval, timeZone: Samples.tokyo)
        return SessionHarness(session: session, manifests: manifests, paths: paths, factory: factory,
                              mic: mic, system: system, clock: clock, disk: disk)
    }

    /// Total seconds of the WAV segments of `track` listed in `m`.
    func duration(_ m: Manifest, _ track: Track) throws -> Double {
        try files(m, track).reduce(0) { $0 + (try WAVFile.info(paths.meetingDirectory(m.id).appending(path: $1.relativePath)).durationSeconds) }
    }

    /// All samples of `track`, segments concatenated in manifest order.
    func samples(_ m: Manifest, _ track: Track) throws -> [Int16] {
        try files(m, track).flatMap { try WAVFile.readSamples(paths.meetingDirectory(m.id).appending(path: $0.relativePath)) }
    }

    func files(_ m: Manifest, _ track: Track) -> [TrackFile] {
        m.tracks.filter { $0.track == track }.sorted { $0.startOffset < $1.startOffset }
    }

    /// Meeting directories under `recordings/` (none when the directory does not exist).
    func meetingDirectories() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: paths.recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
    }
}

/// Events up to and including the next `.stopped` (event streams outlive meetings, so they never finish on their own).
func eventsUntilStopped(_ stream: AsyncStream<RecordingEvent>) async -> [RecordingEvent] {
    var received: [RecordingEvent] = []
    for await event in stream {
        received.append(event)
        if case .stopped = event { break }
    }
    return received
}

struct TimedOut: Error {}

/// Runs `operation` in its own task and gives up after `limit`, even if the operation never returns (a deadlock
/// fails the test instead of hanging the suite).
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let pending = Mutex<CheckedContinuation<T, any Error>?>(nil)
    let finish: @Sendable (Result<T, any Error>) -> Void = { result in
        pending.withLock { c in c?.resume(with: result); c = nil }
    }
    return try await withCheckedThrowingContinuation { continuation in
        pending.withLock { $0 = continuation }
        Task { do { finish(.success(try await operation())) } catch { finish(.failure(error)) } }
        Task { try? await Task.sleep(for: limit); finish(.failure(TimedOut())) }
    }
}
