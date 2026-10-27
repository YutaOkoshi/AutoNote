import Foundation
import Testing
import AutoNoteCore

@Suite struct FailureExplanationTests {
    private let folder = "/Users/u/Documents/AutoNote"
    private func make(_ s: FailureExplanation.Source) -> FailureExplanation { .make(s, outputFolderPath: folder) }
    private func row(_ s: MeetingRowState) -> MeetingRow { MeetingRow(id: "m", state: s) }

    @Test func claudeNotFound() {
        let want = FailureExplanation(what: "議事録を作れませんでした", why: "Claude Code（claude）が見つかりません",
                                      actions: [.installGuide, .redetectClaudeAndRerun], tone: .failure)
        #expect(make(.summary("claude_not_found")) == want && make(.summary("claude_not_found: /opt/homebrew/bin/claude")) == want)
    }

    @Test func notLoggedIn() {
        #expect(make(.summary("not_logged_in")) == FailureExplanation(
            what: "議事録を作れませんでした", why: "Claude Code にログインしていません", actions: [.loginGuide, .rerun], tone: .failure))
    }

    @Test func noSpeech() {
        #expect(make(.job(stage: "transcribe", reason: "no_speech")) == FailureExplanation(
            what: "音声を聞き取れませんでした", why: "録音に声が入っていないか、マイクが拾えていません",
            actions: [.revealAudio, .delete], tone: .failure))
    }

    @Test(arguments: ["output_folder_unavailable", "output_folder_missing"]) func outputFolderWaits(reason: String) {
        for stage in ["write_vault", "update_index"] {
            #expect(make(.job(stage: stage, reason: reason, waiting: true)) == FailureExplanation(
                what: "保存先に書けないので待っています", why: folder, actions: [.changeOutputFolder], tone: .waiting))
        }
    }

    @Test func otherWaiting() {
        #expect(make(.job(stage: "summarize", reason: "rate_limited", waiting: true)) == FailureExplanation(
            what: "議事録の作成を待っています", why: "しばらくしてから自動でやり直します", actions: [], tone: .waiting))
    }

    @Test(arguments: [
        ("transcribe", "final_transcription_failed: TranscriptionError", "文字起こしに失敗しました", "文字起こしエンジンが途中で止まりました"),
        ("summarize", "final_transcript_missing", "議事録の作成に失敗しました", "文字起こしのファイルが見つかりません"),
        ("write_vault", "final_transcript_missing", "保存に失敗しました", "文字起こしのファイルが見つかりません"),
        ("automations", nil, "Automations に失敗しました", "原因がわかりません"),
        ("", "unknown_stage: x", "処理に失敗しました", "原因がわかりません"),
    ] as [(String, String?, String, String)]) func otherJobFailures(stage: String, reason: String?, what: String, why: String) {
        #expect(make(.job(stage: stage, reason: reason)) == FailureExplanation(what: what, why: why, actions: [.rerun], tone: .failure))
    }

    @Test(arguments: [("rate_limited", "Claude Code の利用上限に達しました"), ("context_exceeded", "文字起こしが長すぎました"),
                      ("timed_out", "Claude Code が時間内に応答しませんでした"), ("invalid_output", "Claude Code の出力を読めませんでした"),
                      ("other", "原因がわかりません")]) func otherSummaryFailures(kind: String, why: String) {
        #expect(make(.summary(kind)) == FailureExplanation(what: "議事録を作れませんでした", why: why, actions: [.rerun], tone: .failure))
        #expect(make(.summary(nil)) == FailureExplanation(what: "議事録を作れませんでした", why: "原因がわかりません", actions: [.rerun], tone: .failure))
    }

    @Test func noInternalNamesLeak() throws {
        let sources: [FailureExplanation.Source] = [
            .summary("claude_not_found"), .summary("claude_not_found: /opt/homebrew/bin/claude"), .summary("not_logged_in"),
            .summary("rate_limited"), .summary("context_exceeded"), .summary("timed_out"), .summary("invalid_output"),
            .summary("other"), .summary(nil),
            .job(stage: "transcribe", reason: "no_speech"),
            .job(stage: "write_vault", reason: "output_folder_unavailable", waiting: true),
            .job(stage: "update_index", reason: "output_folder_missing", waiting: true),
            .job(stage: "summarize", reason: "rate_limited", waiting: true),
            .job(stage: "transcribe", reason: "final_transcription_failed: TranscriptionError"),
            .job(stage: "summarize", reason: "final_transcript_missing"),
            .job(stage: "write_vault", reason: "final_transcript_missing"),
            .job(stage: "automations", reason: nil),
            .job(stage: "", reason: "unknown_stage: x"),
        ]
        let pattern = try Regex("[A-Za-z]+_[A-Za-z]+")
        for s in sources {
            let e = make(s)
            let text = e.what + e.why.replacingOccurrences(of: folder, with: "")
            #expect(text.firstMatch(of: pattern) == nil, "\(s)")
            #expect(!text.contains("TranscriptionError"), "\(s)")
        }
    }

    @Test func sourceForRows() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(FailureExplanation.source(row: row(.failed), item: QueueItemDTO(meetingID: "m", stage: "transcribe", state: "failed", message: "no_speech"))
                == .job(stage: "transcribe", reason: "no_speech"))
        #expect(FailureExplanation.source(row: row(.transcriptOnly), item: QueueItemDTO(meetingID: "m", state: "done", summaryFailure: "not_logged_in"))
                == .summary("not_logged_in"))
        #expect(FailureExplanation.source(row: row(.transcriptOnly), item: nil) == .summary(nil))
        #expect(FailureExplanation.source(row: row(.processing), item: QueueItemDTO(meetingID: "m", stage: "write_vault", state: "waiting",
                message: "output_folder_unavailable", notBefore: at)) == .job(stage: "write_vault", reason: "output_folder_unavailable", waiting: true))
        #expect(FailureExplanation.source(row: row(.processing), item: QueueItemDTO(meetingID: "m", stage: "summarize", state: "running")) == nil)
        #expect(FailureExplanation.source(row: row(.failed), item: nil) == .job(stage: "", reason: nil))
        #expect(FailureExplanation.source(row: row(.minutesGenerated), item: nil) == nil)
    }

    @Test func actionTitles() {
        typealias F = FailureExplanation
        #expect(F.actionTitle(.installGuide) == "入れ方を見る")
        #expect(F.actionTitle(.redetectClaudeAndRerun) == "もう一度探して再実行")
        #expect(F.actionTitle(.rerun) == "再実行")
        #expect(F.actionTitle(.openSystemSettings) == "システム設定を開く")
        #expect(F.actionTitle(.revealAudio) == "録音を聞く")
        #expect(F.actionTitle(.delete) == "削除")
        #expect(F.actionTitle(.changeOutputFolder) == "保存先を変える")
        #expect(F.actionTitle(.loginGuide) == "ターミナルで claude を開く手順を見る")
    }
}
