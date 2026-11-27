import Testing
import Foundation
import Synchronization
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

    /// While the recording is paused nothing is written, so those seconds are neither suspect nor lost.
    @Test func secondsInsideAPauseAreNotSuspect() {
        let h = SourceHealth()
        for second in 0..<10 {
            h.recordOutputPoll(at: Double(second), othersPlaying: true)
            if second < 8 { h.recordCallback(start: Double(second), duration: 1, nonZero: false) }   // 8, 9: no callback
        }
        let whole = SourceHealth.summary(track: .system, sources: [h], endSeconds: 10)
        #expect(whole.suspectZeroSeconds == 8 && whole.suspectNoCallbackSeconds == 2 && whole.excludedNoCallbackSeconds == nil)
        // Paused from 2.5 s to 6 s, and again from 8 s with no resume: seconds 3, 4, 5 and 8, 9 are wholly inside.
        let pauses = [PauseInterval(start: .init(seconds: 2.5), end: .init(seconds: 6)), PauseInterval(start: .init(seconds: 8))]
        let s = SourceHealth.summary(track: .system, sources: [h], endSeconds: 10, pauses: pauses)
        #expect(s.zeroSeconds == 8 && s.noCallbackSeconds == 2)      // unchanged counting
        #expect(s.suspectZeroSeconds == 5)                           // 0, 1, 2, 6, 7
        #expect(s.suspectNoCallbackSeconds == 0)
        #expect(s.excludedNoCallbackSeconds == 2)                      // 8, 9
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

    @Test func reportsNotArrivingOncePerStretch() {
        let h = SourceHealth()
        let got = Mutex<[Int?]>([])
        h.reportNotArriving(seconds: 61)
        h.reportNotArriving(seconds: 200)
        h.setNotArrivingObserver { s in got.withLock { $0.append(s) } }     // a late observer still hears the first
        #expect(got.withLock { $0 } == [61])
        h.reportArrivingAgain()
        h.reportArrivingAgain()
        #expect(got.withLock { $0 } == [61, nil])
        h.reportNotArriving(seconds: 70)
        #expect(got.withLock { $0 } == [61, nil, 70])
    }

    /// Nothing is said about a paused recording, and a report its owner could not pass on can be made again.
    @Test func saysNothingWhilePausedAndRepeatsAReportTheOwnerDropped() {
        let h = SourceHealth()
        let got = Mutex<[Int?]>([])
        h.setNotArrivingObserver { s in got.withLock { $0.append(s) } }
        h.setPaused(true)
        h.reportNotArriving(seconds: 90)
        #expect(got.withLock { $0 }.isEmpty)
        h.setPaused(false)
        h.reportNotArriving(seconds: 61)
        h.forgetNotArriving()
        h.reportNotArriving(seconds: 62)
        #expect(got.withLock { $0 } == [61, 62])
    }

    /// The 10 s windows of the drain log: a line at notice level only when the track's state changes.
    @Test func aWindowTellsWhenTheTrackChangesState() {
        let h = SourceHealth()
        h.recordCallback(start: 0, duration: 1, nonZero: true)
        var w = h.closeWindow()
        #expect(w.callbacks == 1 && w.state == .normal && w.changedFrom == nil)      // a track starts out normal
        h.recordCallback(start: 10, duration: 1, nonZero: false)
        h.recordCallback(start: 11, duration: 1, nonZero: false)
        w = h.closeWindow()
        #expect(w.callbacks == 2 && w.state == .allZero && w.changedFrom == .normal)
        h.recordCallback(start: 20, duration: 1, nonZero: false)
        w = h.closeWindow()
        #expect(w.state == .allZero && w.changedFrom == nil)                         // unchanged: nothing to tell
        w = h.closeWindow()
        #expect(w.callbacks == 0 && w.state == .noCallbacks && w.changedFrom == .allZero)
        h.recordCallback(start: 40, duration: 1, nonZero: false)
        h.recordCallback(start: 41, duration: 1, nonZero: true)
        w = h.closeWindow()
        #expect(w.state == .normal && w.changedFrom == .noCallbacks)
    }

    @Test func theNewFieldsAreOptionalInJSON() throws {
        let old = TrackHealth(track: .system, noCallbackSeconds: 3, zeroSeconds: 4, restarts: 1, callbacks: 9)
        let oldJSON = String(decoding: try AutoNoteJSON.encoder().encode(old), as: UTF8.self)
        #expect(!oldJSON.contains("dropped_frames") && !oldJSON.contains("suspect"))
        #expect(try AutoNoteJSON.decoder().decode(TrackHealth.self, from: Data(oldJSON.utf8)) == old)

        var new = old
        new.droppedFrames = 12; new.suspectZeroSeconds = 5; new.suspectNoCallbackSeconds = 6; new.excludedNoCallbackSeconds = 2
        let newJSON = String(decoding: try AutoNoteJSON.encoder().encode(new), as: UTF8.self)
        for key in ["dropped_frames", "suspect_zero_seconds", "suspect_no_callback_seconds", "excluded_no_callback_seconds"] { #expect(newJSON.contains("\"\(key)\"")) }
        #expect(try AutoNoteJSON.decoder().decode(TrackHealth.self, from: Data(newJSON.utf8)) == new)
    }
}

@Suite struct AudioLossRuleTests {
    private static func health(_ track: Track, noCallback: Int = 0, zero: Int = 0, suspectZero: Int? = nil,
                               suspectNoCallback: Int? = nil) -> TrackHealth {
        TrackHealth(track: track, noCallbackSeconds: noCallback, zeroSeconds: zero, restarts: 0, callbacks: 1,
                    droppedFrames: 0, suspectZeroSeconds: suspectZero, suspectNoCallbackSeconds: suspectNoCallback)
    }

    /// A tenth of the recording, but never under 30 s (a short meeting) nor over 3 minutes (a long one).
    @Test func theThresholdIsATenthOfTheRecordingBetweenThirtySecondsAndThreeMinutes() {
        #expect(AudioLossRule.threshold(recordedSeconds: 100) == 30)
        #expect(AudioLossRule.threshold(recordedSeconds: 300) == 30)
        #expect(AudioLossRule.threshold(recordedSeconds: 900) == 90)
        #expect(AudioLossRule.threshold(recordedSeconds: 1800) == 180)
        #expect(AudioLossRule.threshold(recordedSeconds: 3600) == 180)
        #expect(AudioLossRule.threshold(recordedSeconds: 7200) == 180)
    }

    /// Five minutes of the other side missing in an hour-long meeting is told.
    @Test func fiveMinutesMissingInAnHourIsALoss() {
        let h = [Self.health(.system, zero: 400, suspectZero: 300)]
        #expect(AudioLossRule.evaluate(health: h, failedTracks: [], recordedSeconds: 3600)
                == [TrackLoss(track: .system, seconds: 300, sourceFailed: false)])
    }

    /// An in-person meeting recorded with the microphone: nobody plays audio, so the tap delivers nothing at all.
    @Test func aSilentSystemTrackWithNobodyPlayingIsNotALoss() {
        let h = [Self.health(.mic), Self.health(.system, noCallback: 3000, zero: 600, suspectZero: 0, suspectNoCallback: 0)]
        #expect(AudioLossRule.evaluate(health: h, failedTracks: [], recordedSeconds: 3600) == nil)
    }

    @Test func suspectSecondsOfTheSystemTrackAtTheThresholdAreALoss() {
        let below = [Self.health(.system, zero: 400, suspectZero: 100, suspectNoCallback: 59)]
        #expect(AudioLossRule.evaluate(health: below, failedTracks: [], recordedSeconds: 1600) == nil)
        let at = [Self.health(.system, zero: 400, suspectZero: 100, suspectNoCallback: 60)]
        #expect(AudioLossRule.evaluate(health: at, failedTracks: [], recordedSeconds: 1600)
                == [TrackLoss(track: .system, seconds: 160, sourceFailed: false)])
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

    /// A microphone that was gone only while the recording was paused lost nothing.
    @Test func theMicrophonesSecondsInsideAPauseAreNotLost() {
        var h = Self.health(.mic, noCallback: 400)
        h.excludedNoCallbackSeconds = 390
        #expect(AudioLossRule.lostSeconds(h) == 10)
        #expect(AudioLossRule.evaluate(health: [h], failedTracks: [], recordedSeconds: 600) == nil)
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
    static let system12 = TrackLoss(track: .system, seconds: 720, sourceFailed: false)
    static let mic45 = TrackLoss(track: .mic, seconds: 45, sourceFailed: false)

    @Test func namesTheTrackAndHowLong() {
        #expect(AudioLossPresentation.detail([Self.system12]) == "システム音声 約 12 分")
        #expect(AudioLossPresentation.detail([Self.mic45, Self.system12]) == "マイク 45 秒、システム音声 約 12 分")
        #expect(AudioLossPresentation.detail([]) == nil && AudioLossPresentation.detail(nil) == nil)
    }

    /// A failed track lost everything after the failure, which its counted seconds do not show: the failure is
    /// said, whatever the seconds.
    @Test func aFailedTrackSaysTheFailureNotItsSeconds() {
        for seconds in [0, 2, 95] {
            #expect(AudioLossPresentation.detail([TrackLoss(track: .mic, seconds: seconds, sourceFailed: true)]) == "マイク（録音に失敗）")
        }
        #expect(AudioLossPresentation.detail([TrackLoss(track: .system, seconds: 3, sourceFailed: true)]) == "システム音声（録音に失敗）")
    }

    /// Suspect seconds of system audio are a possibility (an app playing digital silence looks the same); a
    /// microphone without callbacks and a failed track are facts.
    @Test func theRowSaysPossiblyOnlyWhenNothingIsCertain() {
        #expect(AudioLossPresentation.rowLabel([Self.system12]) == "録音の欠損の可能性: システム音声 約 12 分")
        #expect(AudioLossPresentation.rowLabel([Self.mic45]) == "録音の欠損: マイク 45 秒")
        // Next to a loss that is a fact, the suspect seconds keep their own "possibly".
        #expect(AudioLossPresentation.rowLabel([Self.mic45, Self.system12]) == "録音の欠損: マイク 45 秒、システム音声 約 12 分（可能性）")
        #expect(AudioLossPresentation.rowLabel([TrackLoss(track: .mic, seconds: 0, sourceFailed: true), Self.system12])
                == "録音の欠損: マイク（録音に失敗）、システム音声 約 12 分（可能性）")
        #expect(AudioLossPresentation.rowLabel([TrackLoss(track: .system, seconds: 0, sourceFailed: true)]) == "録音の欠損: システム音声（録音に失敗）")
        #expect(AudioLossPresentation.rowLabel(nil) == nil && AudioLossPresentation.rowLabel([]) == nil)
    }

    /// A microphone that delivered only zeros for long is not a loss (a muted headset looks the same), but it is
    /// worth a look: said in the row from the same length a loss would be told from.
    @Test func aMicrophoneThatWasAllZerosForLongIsSaidInTheRowOnly() {
        func mic(zero: Int) -> [TrackHealth] {
            [TrackHealth(track: .mic, noCallbackSeconds: 0, zeroSeconds: zero, restarts: 0, callbacks: 1, droppedFrames: 0)]
        }
        let hour = 4140.0   // threshold 180 s
        #expect(AudioLossPresentation.micSilentLabel(health: mic(zero: 1186), losses: nil, recordedSeconds: hour)
                == "マイクが約 20 分、完全な無音でした（ミュートしていたなら問題ありません）")
        #expect(AudioLossPresentation.micSilentLabel(health: mic(zero: 179), losses: nil, recordedSeconds: hour) == nil)
        #expect(AudioLossPresentation.micSilentLabel(health: mic(zero: 45), losses: nil, recordedSeconds: 300)
                == "マイクが 45 秒、完全な無音でした（ミュートしていたなら問題ありません）")
        // A failed microphone is already said as a loss; an unfinished or older recording says nothing.
        #expect(AudioLossPresentation.micSilentLabel(health: mic(zero: 1186), losses: [TrackLoss(track: .mic, seconds: 0, sourceFailed: true)],
                                                     recordedSeconds: hour) == nil)
        #expect(AudioLossPresentation.micSilentLabel(health: mic(zero: 1186), losses: nil, recordedSeconds: nil) == nil)
        #expect(AudioLossPresentation.micSilentLabel(health: nil, losses: nil, recordedSeconds: hour) == nil)
        // It is not a loss: neither the rule nor the note mention it.
        #expect(AudioLossRule.evaluate(health: mic(zero: 1186), failedTracks: [], recordedSeconds: hour) == nil)
    }

    /// One sentence pair per track: whose voice, how sure, and what is missing from the note.
    @Test func theNoteAndTheRowsHelpSayWhoseVoiceIsMissing() {
        let system = "システム音声（相手の声）が約 12 分、録音に入っていない可能性があります。その間に相手が話していた場合、その発言は文字起こしと議事録に入っていません。"
        let mic = "マイク（自分の声）が 45 秒、録音されていません。その間の自分の発言は文字起こしと議事録に入っていません。"
        let systemFailed = "システム音声（相手の声）の録音に失敗しました。失敗した後の相手の発言は文字起こしと議事録に入っていません。"
        let micFailed = "マイク（自分の声）の録音に失敗しました。失敗した後の自分の発言は文字起こしと議事録に入っていません。"
        #expect(AudioLossPresentation.noteLine([Self.system12]) == "> \(system)")
        #expect(AudioLossPresentation.noteLine([Self.mic45, Self.system12]) == "> \(mic)\n> \(system)")
        #expect(AudioLossPresentation.noteLine([TrackLoss(track: .system, seconds: 0, sourceFailed: true)]) == "> \(systemFailed)")
        #expect(AudioLossPresentation.noteLine([TrackLoss(track: .mic, seconds: 2, sourceFailed: true)]) == "> \(micFailed)")
        #expect(AudioLossPresentation.help([Self.mic45, Self.system12]) == mic + system)
        #expect(AudioLossPresentation.noteLine(nil) == nil && AudioLossPresentation.help(nil) == nil)
    }
}
