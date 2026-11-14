@testable import AutoNoteCore
import AutoNoteTestSupport
import Foundation
import Testing

@Suite struct TranslationPresentationTests {
    private let a = utterance(0, "We moved the tenants.")
    private let b = utterance(3, "残りはいつですか。", .me)
    private let marker = Utterance(start: TimelineTime(seconds: 5), speaker: .unknown, text: LiveFeed.pauseMarkerText, isFinal: true)

    private var lines: [LiveLine] { [.utterance(a), .marker(marker), .utterance(b)] }

    private func translated(_ index: Int, _ text: String) -> TranslatedUtterance {
        TranslatedUtterance(index: index, sourceHash: "x", sourceLanguage: .en, targetLanguage: .ja, text: text)
    }

    @Test func finalTranslationsAlignWithTheLinesAndHide() {
        let t = MeetingTranslation(status: .complete, byIndex: [0: translated(0, "テナントを移しました。"), 2: translated(2, "When?")],
                                   hasTranscript: true)
        #expect(TranslationPresentation.finalTranslations(lines, t, shown: true) == ["テナントを移しました。", nil, "When?"])
        #expect(TranslationPresentation.finalTranslations(lines, t, shown: false) == [nil, nil, nil])
        // A line without a translation keeps its plain look (nil), so its height does not jump while waiting.
        let half = MeetingTranslation(status: .partial(done: 1, total: 2), byIndex: [0: translated(0, "訳")], hasTranscript: true)
        #expect(TranslationPresentation.finalTranslations(lines, half, shown: true) == ["訳", nil, nil])
    }

    @Test func liveTranslationsOnlyForConfirmedLines() {
        var partial = b
        partial.isFinal = false
        let live = [TranslationKey.live(a): LiveTranslatedLine(key: TranslationKey.live(a), sourceLanguage: .en,
                                                               targetLanguage: .ja, text: "移しました"),
                    TranslationKey.live(partial): LiveTranslatedLine(key: TranslationKey.live(partial), sourceLanguage: .ja,
                                                                     targetLanguage: .en, text: "never")]
        let rows: [LiveLine] = [.utterance(a), .utterance(partial)]
        #expect(TranslationPresentation.liveTranslations(rows, live, shown: true) == ["移しました", nil])
        #expect(TranslationPresentation.liveTranslations(rows, live, shown: false) == [nil, nil])
    }

    @Test func controlsFollowTheSpec() {
        let none = MeetingTranslation(hasTranscript: true)
        let done = MeetingTranslation(status: .complete, byIndex: [0: translated(0, "x")], hasTranscript: true)
        let stale = MeetingTranslation(status: .stale, hasTranscript: true)
        let partial = MeetingTranslation(status: .partial(done: 3, total: 10), byIndex: [0: translated(0, "x")], hasTranscript: true)

        #expect(TranslationPresentation.controls(job: nil, translation: none, hasTranscript: true, available: true)
            == .init(button: "翻訳する"))
        #expect(TranslationPresentation.controls(job: nil, translation: done, hasTranscript: true, available: true)
            == .init(button: "訳し直す", showsToggle: true))
        let s = TranslationPresentation.controls(job: nil, translation: stale, hasTranscript: true, available: true)
        #expect(s.button == "訳し直す" && s.status?.contains("文字起こしが変わった") == true && !s.showsToggle)
        let p = TranslationPresentation.controls(job: nil, translation: partial, hasTranscript: true, available: true)
        #expect(p.button == "翻訳する" && p.status == "翻訳は途中です（3 / 10）")
        // Not usable (no model, no license, no runtime): no button, but what exists still shows.
        #expect(TranslationPresentation.controls(job: nil, translation: none, hasTranscript: true, available: false).isEmpty)
        #expect(TranslationPresentation.controls(job: nil, translation: done, hasTranscript: true, available: false)
            == .init(showsToggle: true))
        // No final transcript: nothing to translate.
        #expect(TranslationPresentation.controls(job: nil, translation: .empty, hasTranscript: false, available: true).isEmpty)
    }

    @Test func controlsWhileRunningPausedOrFailed() {
        let none = MeetingTranslation(hasTranscript: true)
        let running = TranslationPresentation.controls(job: .running(.init(done: 12, total: 340)), translation: none,
                                                       hasTranscript: true, available: true)
        #expect(running.button == nil && running.status == "翻訳中… 12 / 340")
        #expect(running.progress == 12.0 / 340.0)
        let waiting = TranslationPresentation.controls(job: .waitingForRecording(.init(done: 1, total: 4)), translation: none,
                                                       hasTranscript: true, available: true)
        #expect(waiting.button == nil && waiting.status?.hasPrefix("録音中は翻訳を止めています") == true)
        let finalizing = TranslationPresentation.controls(job: .waitingForTranscription(.init(done: 1, total: 4)),
                                                          translation: none, hasTranscript: true, available: true)
        #expect(finalizing.button == nil && finalizing.status?.hasPrefix("文字起こしの確定を先にするため") == true)
        #expect(finalizing.progress == 0.25)
        let failed = TranslationPresentation.controls(job: .failed("翻訳できませんでした（x）"), translation: none,
                                                      hasTranscript: true, available: true)
        #expect(failed.button == "再試行" && failed.isFailure && failed.status == "翻訳できませんでした（x）")
        #expect(TranslationPresentation.controls(job: .queued, translation: none, hasTranscript: true, available: true).button == nil)
    }

    @Test func settingsOptionsExplainWhatIsOff() {
        let intel8 = MachineProfile(kind: .intel, physicalCores: 4, physicalMemory: 8 << 30)
        let modes = TranslationSettingsPresentation.modes(profile: intel8)
        #expect(modes.map(\.mode) == [.off, .afterRecording, .duringRecording])
        #expect(modes.map { $0.disabledReason != nil } == [false, false, true])
        let rows = TranslationSettingsPresentation.models(profile: intel8)
        #expect(rows.map(\.isDefault) == [true, false, false])
        #expect(rows.map { $0.disabledReason != nil } == [false, false, true])
        #expect(rows[0].title.contains("この Mac の既定"))
        let arm = MachineProfile(kind: .appleSilicon, physicalCores: 10, physicalMemory: 16 << 30)
        #expect(TranslationSettingsPresentation.models(profile: arm).map(\.isDefault) == [false, true, false])
        #expect(TranslationSettingsPresentation.modes(profile: arm).allSatisfy { $0.disabledReason == nil })
    }

    @Test func voiceOverReadsBoth() {
        #expect(TranslationPresentation.accessibilityLabel(original: "Hello.", translation: "こんにちは。")
            == "Hello.。訳文: こんにちは。")
    }
}

@MainActor @Suite struct AppModelTranslationTests {
    @Test func jobsRevisionsLiveLinesAndActions() async throws {
        let fakes = FakePorts()
        let model = AppModel(ports: fakes.ports, now: { Samples.start }, timeZone: Samples.tokyo)
        let task = Task { await model.run() }
        defer { task.cancel() }
        await model.settle()
        #expect(model.translationAvailability == .ready)

        let id = MeetingID(rawValue: "20261024-1400-a1b2")
        await fakes.translation.send(.job(id, .running(.init(done: 1, total: 3)), revision: 0))
        await model.settle()
        #expect(model.translationJobs[id] == .running(.init(done: 1, total: 3)))
        await fakes.translation.send(.job(id, nil, revision: 1))
        await model.settle()
        #expect(model.translationJobs[id] == nil && model.translationRevisions[id] == 1)

        // Live lines are kept only for the recording meeting.
        let line = LiveTranslatedLine(key: "k", sourceLanguage: .en, targetLanguage: .ja, text: "訳")
        await fakes.translation.send(.live(id, line))
        await model.settle()
        #expect(model.liveTranslations.isEmpty)
        await fakes.recorder.send(RecorderSnapshot(state: .recording, meetingID: id, startedAt: Samples.start,
                                                   deviceName: nil, language: .ja))
        await model.settle()
        await fakes.translation.send(.live(id, line))
        await model.settle()
        #expect(model.liveTranslations["k"] == line)

        await model.perform(.translate(id))
        await model.perform(.setTranslationShown(false))
        #expect(!model.translationShown)
        #expect(await fakes.translation.calls.contains("translate \(id.rawValue)"))
        #expect(await fakes.translation.calls.contains("setShown false"))
    }

    @Test func aRefusedTranslateShowsTheErrorAndChangesNothingElse() async {
        let fakes = FakePorts(translation: FakeTranslationPort(available: .licenseNotAccepted))
        let model = AppModel(ports: fakes.ports, now: { Samples.start }, timeZone: Samples.tokyo)
        let task = Task { await model.run() }
        defer { task.cancel() }
        await model.settle()
        #expect(model.translationAvailability == .licenseNotAccepted)
        await model.perform(.translate(MeetingID(rawValue: "20261024-1400-a1b2")))
        #expect(model.lastError != nil)
        #expect(model.recorder.state == .idle)
    }
}
