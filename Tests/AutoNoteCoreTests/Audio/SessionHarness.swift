import Foundation
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
                     system: FakeAudioSource = FakeAudioSource(track: .system)) async throws -> SessionHarness {
        let paths = AppPaths(root: try TemporaryDirectory.make())
        let manifests = ManifestStore(paths: paths)
        let factory = FakeAudioSourceFactory(mic: mic, system: system)
        let clock = FakeHostClock()
        // The production tick task is kept out of the way; tests drive `tick()` themselves.
        let session = RecordingSession(paths: paths, manifests: manifests, sources: factory, host: clock, disk: disk,
                                       now: { Samples.start }, tickInterval: .seconds(3600), timeZone: Samples.tokyo)
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
