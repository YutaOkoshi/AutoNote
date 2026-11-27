import Testing
import Foundation
@testable import AutoNoteCore
import AutoNoteTestSupport

@Suite struct SourceHealthSuspectTests {
    /// Polls of "is another process playing audio" mark whole seconds; only a second whose polls all said yes counts.
    @Test func countsSecondsOtherProcessesPlayedButNothingArrived() {
        let h = SourceHealth()
        h.recordCallback(start: 0, duration: 1, nonZero: true)        // second 0: audio, nobody polled yet
        for t in [1.0, 1.25, 1.5, 1.75] { h.recordOutputPoll(at: t, othersPlaying: true) }
        h.recordCallback(start: 1, duration: 1, nonZero: false)       // second 1: zeros while others play
        for t in [2.0, 2.5] { h.recordOutputPoll(at: t, othersPlaying: true) }   // second 2: no callback while others play
        for t in [3.0, 3.5] { h.recordOutputPoll(at: t, othersPlaying: true) }
        h.recordCallback(start: 3, duration: 1, nonZero: true)        // second 3: audio while others play
        h.recordOutputPoll(at: 4.0, othersPlaying: true)
        h.recordOutputPoll(at: 4.5, othersPlaying: false)             // second 4: playback ended mid-second
        h.recordCallback(start: 4, duration: 1, nonZero: false)
        h.recordOutputPoll(at: 5.0, othersPlaying: false)             // second 5: zeros, nobody plays (plain silence)
        h.recordCallback(start: 5, duration: 1, nonZero: false)
        // second 6: no callback, nobody plays (an idle tap delivers nothing)
        h.recordOutputPoll(at: 6.0, othersPlaying: false)
        let s = SourceHealth.summary(track: .system, sources: [h], endSeconds: 7)
        #expect(s.zeroSeconds == 3)              // 1, 4, 5: unchanged counting
        #expect(s.noCallbackSeconds == 2)        // 2, 6: unchanged counting
        #expect(s.suspectZeroSeconds == 1)       // 1
        #expect(s.suspectNoCallbackSeconds == 1) // 2
    }

    @Test func aSourceThatNeverPolledReportsNoSuspectSeconds() {
        let h = SourceHealth()
        h.recordCallback(start: 0, duration: 1, nonZero: false)
        let s = SourceHealth.summary(track: .mic, sources: [h], endSeconds: 2)
        #expect(s.zeroSeconds == 1 && s.noCallbackSeconds == 1)
        #expect(s.suspectZeroSeconds == nil && s.suspectNoCallbackSeconds == nil)
    }

    @Test func sumsTheDroppedFramesOfEverySource() {
        let a = SourceHealth(), b = SourceHealth()
        a.addDroppedFrames(480); a.addDroppedFrames(20)
        b.addDroppedFrames(7)
        #expect(SourceHealth.summary(track: .mic, sources: [a, b], endSeconds: 1).droppedFrames == 507)
        #expect(SourceHealth.summary(track: .mic, sources: [SourceHealth()], endSeconds: 1).droppedFrames == 0)
    }

    @Test func countsNonZeroCallbacksForTheWatchdog() {
        let h = SourceHealth()
        h.recordCallback(start: 0, duration: 0.01, nonZero: false)
        #expect(h.nonZeroCallbacks == 0)
        h.recordCallback(start: 0.01, duration: 0.01, nonZero: true)
        h.recordCallback(start: 0.02, duration: 0.01, nonZero: true)
        #expect(h.nonZeroCallbacks == 2)
    }

    @Test func reportsNotArrivingOnce() {
        let h = SourceHealth()
        let got = FailureMessage()
        h.reportNotArriving(seconds: 61)
        h.reportNotArriving(seconds: 200)
        h.setNotArrivingObserver { got.set(String($0)) }
        #expect(got.message == "61")
    }

    @Test func theNewFieldsAreOptionalInJSON() throws {
        let old = TrackHealth(track: .system, noCallbackSeconds: 3, zeroSeconds: 4, restarts: 1, callbacks: 9)
        let oldJSON = String(decoding: try AutoNoteJSON.encoder().encode(old), as: UTF8.self)
        #expect(!oldJSON.contains("dropped_frames") && !oldJSON.contains("suspect"))
        #expect(try AutoNoteJSON.decoder().decode(TrackHealth.self, from: Data(oldJSON.utf8)) == old)

        var new = old
        new.droppedFrames = 12; new.suspectZeroSeconds = 5; new.suspectNoCallbackSeconds = 6
        let newJSON = String(decoding: try AutoNoteJSON.encoder().encode(new), as: UTF8.self)
        for key in ["dropped_frames", "suspect_zero_seconds", "suspect_no_callback_seconds"] { #expect(newJSON.contains("\"\(key)\"")) }
        #expect(try AutoNoteJSON.decoder().decode(TrackHealth.self, from: Data(newJSON.utf8)) == new)
    }
}

@Suite struct AudioLossRuleTests {
    private static func health(_ track: Track, noCallback: Int = 0, zero: Int = 0, suspectZero: Int? = nil,
                               suspectNoCallback: Int? = nil) -> TrackHealth {
        TrackHealth(track: track, noCallbackSeconds: noCallback, zeroSeconds: zero, restarts: 0, callbacks: 1,
                    droppedFrames: 0, suspectZeroSeconds: suspectZero, suspectNoCallbackSeconds: suspectNoCallback)
    }

    @Test func theThresholdIsThirtySecondsOrATenthOfTheRecording() {
        #expect(AudioLossRule.threshold(recordedSeconds: 100) == 30)
        #expect(AudioLossRule.threshold(recordedSeconds: 300) == 30)
        #expect(AudioLossRule.threshold(recordedSeconds: 3600) == 360)
    }

    /// An in-person meeting recorded with the microphone: nobody plays audio, so the tap delivers nothing at all.
    @Test func aSilentSystemTrackWithNobodyPlayingIsNotALoss() {
        let h = [Self.health(.mic), Self.health(.system, noCallback: 3000, zero: 600, suspectZero: 0, suspectNoCallback: 0)]
        #expect(AudioLossRule.evaluate(health: h, failedTracks: [], recordedSeconds: 3600) == nil)
    }

    @Test func suspectSecondsOfTheSystemTrackAtTheThresholdAreALoss() {
        let below = [Self.health(.system, zero: 400, suspectZero: 200, suspectNoCallback: 159)]
        #expect(AudioLossRule.evaluate(health: below, failedTracks: [], recordedSeconds: 3600) == nil)
        let at = [Self.health(.system, zero: 400, suspectZero: 200, suspectNoCallback: 160)]
        #expect(AudioLossRule.evaluate(health: at, failedTracks: [], recordedSeconds: 3600)
                == [TrackLoss(track: .system, seconds: 360, sourceFailed: false)])
        let short = [Self.health(.system, suspectZero: 30)]
        #expect(AudioLossRule.evaluate(health: short, failedTracks: [], recordedSeconds: 90)
                == [TrackLoss(track: .system, seconds: 30, sourceFailed: false)])
    }

    /// A headset's mute button delivers exact zeros, so the microphone's zero seconds are not a loss; missing callbacks are.
    @Test func theMicrophoneLosesOnlyTheSecondsWithoutCallbacks() {
        let muted = [Self.health(.mic, zero: 1200)]
        #expect(AudioLossRule.evaluate(health: muted, failedTracks: [], recordedSeconds: 3600) == nil)
        let dead = [Self.health(.mic, noCallback: 400, zero: 10)]
        #expect(AudioLossRule.evaluate(health: dead, failedTracks: [], recordedSeconds: 3600)
                == [TrackLoss(track: .mic, seconds: 400, sourceFailed: false)])
    }

    @Test func aFailedTrackIsALossWhateverItsSeconds() {
        let h = [Self.health(.mic, noCallback: 3)]
        #expect(AudioLossRule.evaluate(health: h, failedTracks: [.mic, .system], recordedSeconds: 600)
                == [TrackLoss(track: .mic, seconds: 3, sourceFailed: true), TrackLoss(track: .system, seconds: 0, sourceFailed: true)])
        #expect(AudioLossRule.evaluate(health: nil, failedTracks: [], recordedSeconds: 600) == nil)
    }

    /// Recordings made before the suspect counters existed never count as lost.
    @Test func olderHealthWithoutSuspectCountersIsNotALoss() {
        let old = [TrackHealth(track: .system, noCallbackSeconds: 900, zeroSeconds: 2000, restarts: 0, callbacks: 5)]
        #expect(AudioLossRule.evaluate(health: old, failedTracks: [], recordedSeconds: 3600) == nil)
    }
}

@Suite struct AudioLossManifestTests {
    @Test func aManifestWithoutTheNewKeysStillLoads() throws {
        var m = Samples.manifest
        m.audioHealth = [TrackHealth(track: .system, noCallbackSeconds: 1, zeroSeconds: 2, restarts: 0, callbacks: 3)]
        let json = String(decoding: try AutoNoteJSON.encoder().encode(m), as: UTF8.self)
        #expect(!json.contains("audio_loss") && !json.contains("dropped_frames"))
        let loaded = try AutoNoteJSON.decoder().decode(Manifest.self, from: Data(json.utf8))
        #expect(loaded == m && loaded.audioLoss == nil)
    }

    @Test func theLossIsSavedUnderAudioLoss() throws {
        var m = Samples.manifest
        m.audioLoss = [TrackLoss(track: .system, seconds: 720, sourceFailed: false)]
        let json = String(decoding: try AutoNoteJSON.encoder().encode(m), as: UTF8.self)
        #expect(json.contains("\"audio_loss\"") && json.contains("\"source_failed\""))
        #expect(try AutoNoteJSON.decoder().decode(Manifest.self, from: Data(json.utf8)) == m)
    }
}

@Suite struct AudioLossPresentationTests {
    @Test func namesTheTrackAndHowLong() {
        #expect(AudioLossPresentation.detail([TrackLoss(track: .system, seconds: 720, sourceFailed: false)]) == "システム音声 約 12 分")
        #expect(AudioLossPresentation.detail([TrackLoss(track: .mic, seconds: 45, sourceFailed: false),
                                              TrackLoss(track: .system, seconds: 95, sourceFailed: true)])
                == "マイク 45 秒、システム音声 約 2 分")
        #expect(AudioLossPresentation.detail([TrackLoss(track: .system, seconds: 0, sourceFailed: true)]) == "システム音声（録音できませんでした）")
        #expect(AudioLossPresentation.detail([]) == nil && AudioLossPresentation.detail(nil) == nil)
    }

    @Test func theRowLabelAndTheNoteLineCarryTheDetail() {
        let loss = [TrackLoss(track: .system, seconds: 720, sourceFailed: false)]
        #expect(AudioLossPresentation.rowLabel(loss) == "録音の欠損: システム音声 約 12 分")
        #expect(AudioLossPresentation.noteLine(loss)?.contains("システム音声 約 12 分") == true)
        #expect(AudioLossPresentation.rowLabel(nil) == nil && AudioLossPresentation.noteLine(nil) == nil)
    }
}
