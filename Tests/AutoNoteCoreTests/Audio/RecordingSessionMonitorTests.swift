import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct RecordingSessionMonitorTests {
    @Test func warnsOnceBelow1GB() async throws {
        let h = try await SessionHarness.make(disk: FakeDiskSpace(bytes: 2_000_000_000))
        let events = await h.session.events()
        _ = try await h.session.start(.init(language: .ja))
        h.disk.bytes = 900_000_000
        h.clock.advance(10); await h.session.tick()
        h.clock.advance(10); await h.session.tick()
        _ = try await h.session.stop()
        let low = await eventsUntilStopped(events).compactMap { e -> Int64? in
            if case .diskSpaceLow(let bytes) = e { bytes } else { nil }
        }
        #expect(low == [900_000_000])
    }

    @Test func checksDiskOnlyEveryTenMeetingSeconds() async throws {
        let h = try await SessionHarness.make(disk: FakeDiskSpace(bytes: 2_000_000_000))
        let events = await h.session.events()
        _ = try await h.session.start(.init(language: .ja))
        #expect(h.disk.calls == 1)                          // the check before starting
        h.clock.advance(1); await h.session.tick()          // first tick checks: 2 GB, fine
        #expect(h.disk.calls == 2)
        h.disk.bytes = 900_000_000
        h.clock.advance(5); await h.session.tick()          // 5 s since the last check: skipped
        #expect(h.disk.calls == 2)
        h.clock.advance(4.9); await h.session.tick()        // 9.9 s: still skipped
        #expect(h.disk.calls == 2)
        h.clock.advance(0.1); await h.session.tick()        // 10 s: checked
        #expect(h.disk.calls == 3)
        _ = try await h.session.stop()
        let received = await eventsUntilStopped(events)
        #expect(received.filter { if case .diskSpaceLow = $0 { true } else { false } }.count == 1)
    }

    @Test func stopsBelow500MBAndKeepsAudio() async throws {
        let h = try await SessionHarness.make()
        let session = h.session
        let events = await session.events()
        _ = try await session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 70))
        h.clock.advance(70)
        await session.waitUntilIdle()
        h.disk.bytes = 400_000_000
        await session.tick()
        let received = try await withTimeout(.seconds(5)) { await eventsUntilStopped(events) }
        guard case .stopped(let m, .diskFull) = received.last else {
            Issue.record("expected .stopped(_, .diskFull), got \(String(describing: received.last))"); return
        }
        #expect(received.contains(.diskSpaceLow(availableBytes: 400_000_000)))
        #expect(await session.state == .idle)
        #expect(m.status == .recorded)
        #expect(try await h.manifests.load(m.id) == m)
        #expect(abs(try h.duration(m, .mic) - 70) < 0.05)
    }

    @Test func stopAfterEarlierLowWarningSendsOneOfEach() async throws {
        let h = try await SessionHarness.make(disk: FakeDiskSpace(bytes: 900_000_000))
        let events = await h.session.events()
        _ = try await h.session.start(.init(language: .ja))
        h.clock.advance(10); await h.session.tick()
        h.disk.bytes = 400_000_000
        h.clock.advance(10); await h.session.tick()
        h.clock.advance(10); await h.session.tick()         // after the stop request: no second stop
        let received = try await withTimeout(.seconds(5)) { await eventsUntilStopped(events) }
        #expect(received.filter { if case .diskSpaceLow = $0 { true } else { false } } == [.diskSpaceLow(availableBytes: 900_000_000)])
        #expect(received.filter { if case .stopped(_, .diskFull) = $0 { true } else { false } }.count == 1)
        #expect(await h.session.state == .idle)
    }

    @Test func providerErrorAtStartDoesNotBlockRecording() async throws {
        let disk = FakeDiskSpace(); disk.error = DiskSpaceError.unavailable(path: "/nowhere")
        let h = try await SessionHarness.make(disk: disk)
        let id = try await h.session.start(.init(language: .ja))
        #expect(await h.session.state == .recording(id))
        #expect(try await h.manifests.load(id).status == .recording)
        #expect(disk.calls == 1)
        _ = try await h.session.stop()
    }

    @Test func providerErrorDuringTickIsSkipped() async throws {
        let h = try await SessionHarness.make()
        let events = await h.session.events()
        let id = try await h.session.start(.init(language: .ja))
        h.disk.error = DiskSpaceError.unavailable(path: "/nowhere")
        h.clock.advance(10); await h.session.tick()
        #expect(h.disk.calls == 2)
        try await Task.sleep(for: .milliseconds(50))         // a wrongly spawned stop would have run by now
        #expect(await h.session.state == .recording(id))
        let m = try await h.session.stop()
        let received = await eventsUntilStopped(events)
        #expect(!received.contains { if case .diskSpaceLow = $0 { true } else { false } })
        #expect(received.last == .stopped(m, .manual))
    }

    @Test func refusesToStartBelow500MB() async throws {
        let h = try await SessionHarness.make(disk: FakeDiskSpace(bytes: 100_000_000))
        await #expect(throws: RecordingError.insufficientDiskSpace(availableBytes: 100_000_000)) {
            try await h.session.start(.init(language: .ja))
        }
        #expect(await h.session.state == .idle)
        #expect(await !h.mic.isStarted)
        #expect(h.meetingDirectories().isEmpty)
    }

    @Test func micSilenceWarningSetsManifestFlag() async throws {
        let h = try await SessionHarness.make()
        let events = await h.session.events()
        let id = try await h.session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.zeros(start: 0, seconds: 15))
        h.clock.advance(15)
        await h.session.waitUntilIdle()
        await h.session.tick()
        #expect(try await h.manifests.load(id).silenceWarning == true)
        _ = try await h.session.stop()
        let received = await eventsUntilStopped(events)
        #expect(received.contains(.silenceWarning(.init(track: .mic, message: SilenceMonitor.micMessage))))
    }

    @Test func systemSilenceWarningAfter60sWithoutCallbacks() async throws {
        let h = try await SessionHarness.make()
        let events = await h.session.events()
        let id = try await h.session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 60))
        h.clock.advance(60); await h.session.waitUntilIdle(); await h.session.tick()
        await h.mic.emit(AudioFixtures.tone(start: 60, seconds: 60))
        h.clock.advance(60); await h.session.waitUntilIdle(); await h.session.tick()
        #expect(try await h.manifests.load(id).silenceWarning == true)
        _ = try await h.session.stop()
        let warnings = await eventsUntilStopped(events).compactMap { e -> SilenceWarning? in
            if case .silenceWarning(let w) = e { w } else { nil }
        }
        #expect(warnings == [SilenceWarning(track: .system, message: SilenceMonitor.systemMessage)])
    }

    @Test func systemDiskSpaceReadsTheNearestExistingDirectory() throws {
        let root = try TemporaryDirectory.make()
        let missing = root.appending(path: "recordings/not-yet", directoryHint: .isDirectory)
        #expect(try SystemDiskSpace().availableBytes(for: missing) > 0)
    }
}
