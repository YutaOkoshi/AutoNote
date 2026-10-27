import Foundation
import Testing
import AutoNoteCore

@Suite struct FlowPresentationTests {
    @Test func durationTextForList() {
        #expect(DurationText.list(seconds: 32, minutes: 1) == "32 秒" && DurationText.list(seconds: 59, minutes: 1) == "59 秒")
        #expect(DurationText.list(seconds: 252, minutes: 4) == "4 分" && DurationText.list(seconds: nil, minutes: 4) == "4 分")
        #expect(DurationText.list(seconds: nil, minutes: nil) == nil)
    }

    @Test func durationTextSpoken() {
        #expect(DurationText.spoken(252) == "4 分 12 秒")
        #expect(DurationText.spoken(32) == "32 秒")
        #expect(DurationText.spoken(120) == "2 分")
    }

    @Test func shortRecordingBand() {
        #expect(ShortRecordingCopy.band(seconds: 32) == "32 秒の録音です。1 分未満なので自動では処理しません。文字起こしと議事録を作りますか？")
        #expect(ShortRecordingCopy.band(seconds: nil) == "1 分未満の録音です。自動では処理しません。文字起こしと議事録を作りますか？")
        #expect(ShortRecordingCopy.transcribeTitle == "作る" && ShortRecordingCopy.discardTitle == "削除")
    }

    @Test(arguments: [("transcribe", "文字起こし中…"), ("summarize", "議事録を作成中…"), ("write_vault", "保存中…"),
                      ("update_index", "保存中…"), ("automations", "保存中…"), ("", "処理中…")])
    func processingHeadings(stage: String, heading: String) {
        #expect(ProcessingPresentation.heading(stage: stage) == heading)
    }

    @Test func engineNote() {
        #expect(ProcessingPresentation.engineNote(stage: "transcribe", model: .installed("base")) == "whisper base")
        #expect(ProcessingPresentation.engineNote(stage: "transcribe", model: .downloading("base", fraction: 0.1)) == "Apple 音声入力（whisper はダウンロード中）")
        #expect(ProcessingPresentation.engineNote(stage: "transcribe", model: .none) == "Apple 音声入力")
        #expect(ProcessingPresentation.engineNote(stage: "transcribe", model: .failed("base", reason: "x")) == "Apple 音声入力")
        #expect(ProcessingPresentation.engineNote(stage: "summarize", model: .installed("base")) == nil)
    }

    @Test func bands() {
        #expect(ProcessingPresentation.stoppedBand(seconds: 252) == "録音を保存しました（4 分 12 秒）")
        #expect(ProcessingPresentation.savedBand(path: "/Users/u/Documents/AutoNote/2026-10-27_1400_発売準備会議.md", home: "/Users/u")
                == "議事録を保存しました — ~/Documents/AutoNote/2026-10-27_1400_発売準備会議.md")
        #expect(ProcessingPresentation.explainer == "文字起こし → 議事録の作成 → 保存 の順に進みます。終わると議事録がここに開きます。")
    }

    @Test func toolbarActionsByState() {
        #expect(MainToolbar.actions(for: .idle) == [.start] && MainToolbar.actions(for: .countdown) == [.cancelCountdown])
        #expect(MainToolbar.actions(for: .recording) == [.stop] && MainToolbar.actions(for: .grace) == [.stop])
        #expect(MainToolbar.actions(for: .paused) == [.stop, .resume])
    }
}
