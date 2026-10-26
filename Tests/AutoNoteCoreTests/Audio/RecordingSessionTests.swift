import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

private func t(_ s: Double) -> TimelineTime { TimelineTime(seconds: s) }

@Suite struct RecordingSessionTests {
    @Test func startWritesRecordingManifest() async throws {
        let h = try await SessionHarness.make()
        let id = try await h.session.start(.init(language: .ja, device: DeviceRef(name: "Test Mic", uid: "TEST:input", transport: "usb")))
        let m = try await h.manifests.load(id)
        #expect(m.status == .recording && m.source == .live && m.language == .ja && m.device?.uid == "TEST:input")
        #expect(m.startedAt == Samples.start && m.silenceWarning == false && m.autonoteVersion == AutoNoteVersion.current)
        #expect(id.rawValue.hasPrefix("20261024-1400-"))
        #expect(Set(m.tracks.map(\.track)) == [.mic, .system])
        #expect(await h.session.state == .recording(id))
        #expect(await h.mic.isStarted); #expect(await h.system.isStarted)
        _ = try await h.session.stop()
    }

    @Test func deviceDefaultsToFactoryInputDevice() async throws {
        let h = try await SessionHarness.make()
        h.factory.devices["USB:input"] = DeviceRef(name: "USB Mic", uid: "USB:input", transport: "usb")
        let id = try await h.session.start(.init(language: .en, microphoneUID: "USB:input"))
        #expect(try await h.manifests.load(id).device?.uid == "USB:input")
        #expect(h.factory.microphoneUIDs == ["USB:input"])
        _ = try await h.session.stop()
    }

    @Test func systemTrackIsPaddedToMicLength() async throws {
        let h = try await SessionHarness.make(); _ = try await h.session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 12))
        await h.system.emit(AudioFixtures.tone(start: 0, seconds: 1)); await h.system.emit(AudioFixtures.tone(start: 10, seconds: 1))
        h.clock.advance(12); let m = try await h.session.stop()
        #expect(try abs(h.duration(m, .system) - 12) < 0.05 && abs(h.duration(m, .mic) - 12) < 0.05)
        #expect(m.tracks.allSatisfy { $0.durationSeconds != nil })
        #expect(try await h.manifests.load(m.id) == m)
    }

    @Test func pauseSkipsAudioAndRecordsInterval() async throws {
        let h = try await SessionHarness.make(); let id = try await h.session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 10))
        h.clock.advance(10); try await h.session.pause()
        #expect(await h.session.state == .paused(id))
        await h.mic.emit(AudioFixtures.tone(start: 10, seconds: 10, value: 2000))
        await h.session.waitUntilIdle()
        h.clock.advance(10); try await h.session.resume()
        await h.mic.emit(AudioFixtures.tone(start: 20, seconds: 5))
        h.clock.advance(5); let m = try await h.session.stop()
        #expect(m.pauses == [PauseInterval(start: t(10), end: t(20))])
        let mic = h.files(m, .mic)
        #expect(mic.map(\.startOffset) == [t(0), t(20)])
        #expect(mic.compactMap(\.durationSeconds).map { ($0 * 100).rounded() / 100 } == [10, 5])
        #expect(try !h.samples(m, .mic).contains(2000))
        #expect(h.files(m, .system).map(\.startOffset) == [t(0), t(20)])
    }

    @Test func bookmarkUsesTimelineAndWorksWhilePaused() async throws {
        let h = try await SessionHarness.make(); let id = try await h.session.start(.init(language: .ja))
        h.clock.advance(5)
        let first = try await h.session.bookmark(note: "決定")
        try await h.session.pause()
        h.clock.advance(3)
        try await h.session.bookmark()
        #expect(first == Bookmark(at: t(5), note: "決定"))
        #expect(try await h.manifests.load(id).bookmarks == [Bookmark(at: t(5), note: "決定"), Bookmark(at: t(8), note: nil)])
        _ = try await h.session.stop()
    }

    @Test(arguments: [(59.9, MeetingStatus.tooShort), (60.0, .recorded)])
    func shortRecordingIsMarkedTooShort(seconds: Double, expected: MeetingStatus) async throws {
        let h = try await SessionHarness.make(); _ = try await h.session.start(.init(language: .ja))
        h.clock.advance(seconds)
        let m = try await h.session.stop()
        #expect(m.status == expected)
        #expect(m.endedAt == Samples.start.addingTimeInterval(seconds))
        #expect(await h.session.state == .idle)
        #expect(await h.session.elapsed() == .zero)
    }

    @Test func micPermissionDeniedRefusesToStart() async throws {
        let h = try await SessionHarness.make(mic: FakeAudioSource(track: .mic, startError: AudioSourceError.microphonePermission(.denied)))
        await #expect(throws: RecordingError.microphonePermission(.denied)) { try await h.session.start(.init(language: .ja)) }
        #expect(await !h.system.isStarted)
        #expect(h.meetingDirectories().isEmpty)
        #expect(await h.session.state == .idle)
    }

    @Test func systemFailureContinuesWithMic() async throws {
        let h = try await SessionHarness.make(system: FakeAudioSource(track: .system, startError: AudioSourceError.coreAudio(call: "AudioHardwareCreateProcessTap", status: -1)))
        let events = await h.session.events()
        let id = try await h.session.start(.init(language: .ja))
        #expect(try await h.manifests.load(id).silenceWarning == true)
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 2))
        h.clock.advance(2)
        let m = try await h.session.stop()
        #expect(m.silenceWarning)
        #expect(abs(try h.duration(m, .mic) - 2) < 0.05)
        #expect(try h.samples(m, .mic).contains(1000))
        let received = await eventsUntilStopped(events)
        #expect(received.contains { if case .sourceFailed(.system, _) = $0 { true } else { false } })
        #expect(received.first == .started(id) && received.last == .stopped(m, .manual))
    }

    @Test func bothFailThrowsAllSourcesFailed() async throws {
        let h = try await SessionHarness.make(
            mic: FakeAudioSource(track: .mic, startError: AudioSourceError.deviceNotFound(uid: "GONE:input")),
            system: FakeAudioSource(track: .system, startError: AudioSourceError.coreAudio(call: "AudioHardwareCreateProcessTap", status: -1)))
        await #expect {
            try await h.session.start(.init(language: .ja))
        } throws: { error in
            guard case RecordingError.allSourcesFailed(let message) = error else { return false }
            return message.contains("deviceNotFound") && message.contains("AudioHardwareCreateProcessTap")
        }
        #expect(h.meetingDirectories().isEmpty)
        #expect(await h.session.state == .idle)
    }

    @Test func detachThenAttachFillsMicWithSilence() async throws {
        let h = try await SessionHarness.make()
        let events = await h.session.events()
        _ = try await h.session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 5))
        h.clock.advance(5); try await h.session.detachMicrophone()
        #expect(await h.mic.stopCount == 1)
        h.clock.advance(10)
        let newMic = FakeAudioSource(track: .mic)
        h.factory.nextMicrophone = newMic
        try await h.session.attachMicrophone(deviceUID: "NEW:input")
        #expect(await newMic.isStarted)
        await newMic.emit(AudioFixtures.tone(start: 15, seconds: 5))
        h.clock.advance(5); let m = try await h.session.stop()
        #expect(abs(try h.duration(m, .mic) - 20) < 0.05)
        let samples = try h.samples(m, .mic)
        let sr = Int(AudioChunk.sampleRate)
        #expect(samples[0..<(5 * sr)].allSatisfy { $0 == 1000 })
        #expect(samples[(5 * sr)..<(15 * sr)].allSatisfy { $0 == 0 })
        #expect(samples[(15 * sr)..<(20 * sr)].allSatisfy { $0 == 1000 })
        #expect(h.factory.microphoneUIDs == [nil, "NEW:input"])
        let received = await eventsUntilStopped(events)
        #expect(received.contains(.microphoneDetached(t(5))))
        #expect(received.contains(.microphoneAttached(t(15), device: nil)))
    }

    @Test func audioStreamYieldsOnlyWhileRecording() async throws {
        let h = try await SessionHarness.make(); _ = try await h.session.start(.init(language: .ja))
        let audio = await h.session.audio(for: .mic)
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 1))
        await h.session.waitUntilIdle()
        h.clock.advance(1); try await h.session.pause()
        await h.mic.emit(AudioFixtures.tone(start: 1, seconds: 1, value: 2000))
        await h.session.waitUntilIdle()
        h.clock.advance(1); try await h.session.resume()
        await h.mic.emit(AudioFixtures.tone(start: 2, seconds: 1, value: 3000))
        await h.system.emit(AudioFixtures.tone(start: 2, seconds: 1, value: 4000, track: .system))
        h.clock.advance(1); _ = try await h.session.stop()
        var chunks: [AudioChunk] = []
        for await c in audio { chunks.append(c) }   // finished by stop
        #expect(chunks.map { $0.samples.first } == [1000, 3000])
        #expect(chunks.allSatisfy { $0.track == .mic })
    }

    @Test func audioCalledAgainFinishesPreviousStream() async throws {
        let h = try await SessionHarness.make(); _ = try await h.session.start(.init(language: .ja))
        let first = await h.session.audio(for: .system)
        let second = await h.session.audio(for: .system)
        var firstChunks: [AudioChunk] = []
        for await c in first { firstChunks.append(c) }   // returns because the second call finished it
        await h.system.emit(AudioFixtures.tone(start: 0, seconds: 1, track: .system))
        h.clock.advance(1); _ = try await h.session.stop()
        var secondChunks: [AudioChunk] = []
        for await c in second { secondChunks.append(c) }
        #expect(firstChunks.isEmpty && secondChunks.count == 1)
    }

    @Test func invalidTransitionsThrow() async throws {
        let h = try await SessionHarness.make()
        await #expect(throws: RecordingError.notRecording) { try await h.session.pause() }
        await #expect(throws: RecordingError.notRecording) { try await h.session.stop() }
        await #expect(throws: RecordingError.notRecording) { try await h.session.bookmark() }
        await #expect(throws: RecordingError.notRecording) { try await h.session.resume() }
        _ = try await h.session.start(.init(language: .ja))
        await #expect(throws: RecordingError.alreadyRecording) { try await h.session.start(.init(language: .ja)) }
        await #expect(throws: RecordingError.notPaused) { try await h.session.resume() }
        try await h.session.pause()
        await #expect(throws: RecordingError.alreadyPaused) { try await h.session.pause() }
        _ = try await h.session.stop()
    }

    @Test func setLanguageUpdatesManifest() async throws {
        let h = try await SessionHarness.make(); let id = try await h.session.start(.init(language: .ja))
        try await h.session.setLanguage(.en)
        #expect(try await h.manifests.load(id).language == .en)
        let m = try await h.session.stop()
        #expect(m.language == .en)
    }

    @Test func eventsReachEverySubscriber() async throws {
        let h = try await SessionHarness.make()
        let s1 = await h.session.events(), s2 = await h.session.events()
        #expect(await h.session.subscriberCount == 2)
        let id = try await h.session.start(.init(language: .ja))
        let b = try await h.session.bookmark(note: "x")
        var it1 = s1.makeAsyncIterator(), it2 = s2.makeAsyncIterator()
        #expect(await it1.next() == .started(id)); #expect(await it1.next() == .bookmarked(b))
        #expect(await it2.next() == .started(id)); #expect(await it2.next() == .bookmarked(b))
        // Cancel the second subscriber: a task waiting on it is cancelled, which terminates the stream.
        let waiting = Task { var it = s2.makeAsyncIterator(); return await it.next() }
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(await h.session.subscriberCount == 1)
        let m = try await h.session.stop()
        #expect(await it1.next() == .stopped(m, .manual))
        // Event streams outlive a meeting: the surviving subscriber also sees the next one.
        let id2 = try await h.session.start(.init(language: .en))
        #expect(id2 != id)
        #expect(await it1.next() == .started(id2))
        _ = try await h.session.stop()
    }

    @Test func eventsBeforeSubscriptionAreNotReplayed() async throws {
        let h = try await SessionHarness.make(); _ = try await h.session.start(.init(language: .ja))
        let late = await h.session.events()
        h.clock.advance(1); try await h.session.pause()
        _ = try await h.session.stop()
        let received = await eventsUntilStopped(late)
        #expect(received.first == .paused(t(1)) && received.count == 2)
    }

    @Test func silenceTickWarnsOnceAndFlagsManifest() async throws {
        let h = try await SessionHarness.make()
        let events = await h.session.events()
        let id = try await h.session.start(.init(language: .ja))
        h.clock.advance(SilenceMonitor.micWindowSeconds)
        await h.session.tick()
        #expect(try await h.manifests.load(id).silenceWarning)
        await h.session.tick()
        _ = try await h.session.stop()
        let warnings = await eventsUntilStopped(events).compactMap { e -> SilenceWarning? in
            if case .silenceWarning(let w) = e { w } else { nil }
        }
        #expect(warnings == [SilenceWarning(track: .mic, message: SilenceMonitor.micMessage)])
    }

    @Test func statisticsCountWrittenChunks() async throws {
        let h = try await SessionHarness.make(); _ = try await h.session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 1, value: Int16.max))
        await h.mic.emit(AudioFixtures.tone(start: 1, seconds: 1))
        await h.session.waitUntilIdle()
        let stats = await h.session.statistics()
        #expect(stats[.mic]?.chunks == 2 && stats[.mic]?.samples == 32_000)
        #expect(abs((stats[.mic]?.peakDBFS ?? -100)) < 0.01)
        #expect(stats[.system]?.chunks == 0)
        _ = try await h.session.stop()
    }

    @Test func waitUntilIdleReturnsWhenNothingQueued() async throws {
        let h = try await SessionHarness.make()
        let session = h.session
        try await withTimeout(.seconds(2)) { await session.waitUntilIdle() }
        #expect(await session.state == .idle)
        let id = try await session.start(.init(language: .ja))
        try await withTimeout(.seconds(2)) { await session.waitUntilIdle() }
        #expect(await session.state == .recording(id))
        #expect(await session.statistics()[.mic]?.chunks == 0)
        _ = try await session.stop()
    }

    @Test func tickerRaisesSilenceWarningAndStopStillReturns() async throws {
        let h = try await SessionHarness.make(tickInterval: .milliseconds(20))
        let session = h.session
        let events = await session.events()
        _ = try await session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.zeros(start: 0, seconds: 15))
        h.clock.advance(15)
        try await Task.sleep(for: .milliseconds(100))
        // Only the real ticker can have produced the warning: `tick()` is never called here.
        let warning = try await withTimeout(.seconds(2)) { () -> SilenceWarning? in
            for await e in events { if case .silenceWarning(let w) = e { return w } }
            return nil
        }
        #expect(warning?.track == .mic)
        let m = try await withTimeout(.seconds(2)) { try await session.stop() }
        #expect(m.silenceWarning && m.status == .tooShort)
    }

    @Test func writerFailureIsReportedAndResumeThrows() async throws {
        let h = try await SessionHarness.make()
        let events = await h.session.events()
        let id = try await h.session.start(.init(language: .ja))
        h.clock.advance(1); try await h.session.pause()
        let tracks = h.paths.tracksDirectory(id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tracks.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tracks.path) }
        h.clock.advance(1)
        await #expect(throws: (any Error).self) { try await h.session.resume() }   // new segments cannot be created
        #expect(await h.session.state == .recording(id))
        #expect(try await h.manifests.load(id).silenceWarning)
        await h.mic.emit(AudioFixtures.tone(start: 2, seconds: 1))                 // dropped: the mic writer failed
        await h.session.waitUntilIdle()
        #expect(await h.session.statistics()[.mic]?.chunks == 0)
        h.clock.advance(1); _ = try await h.session.stop()
        let failed = await eventsUntilStopped(events).compactMap { e -> Track? in
            if case .sourceFailed(let track, _) = e { track } else { nil }
        }
        #expect(failed.filter { $0 == .mic }.count == 1)
    }

    @Test func liveUsesVoiceProcessingSetting() async throws {
        var settings = Settings(); settings.voiceProcessing = true
        let session = RecordingSession.live(paths: AppPaths(root: try TemporaryDirectory.make()), settings: settings)
        let factory = try #require(session.sources as? LiveAudioSourceFactory)
        #expect(factory.voiceProcessing == true)
        #expect(await session.state == .idle)
    }
}
