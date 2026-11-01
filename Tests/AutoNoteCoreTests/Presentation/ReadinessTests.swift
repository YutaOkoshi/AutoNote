import Foundation
import Testing
import AutoNoteCore

@Suite struct ReadinessTests {
    private let home = "/Users/u"
    private let ok = Readiness(outputFolder: .init(path: "/Users/u/Documents/AutoNote", available: true),
                               model: .installed("base"), claude: .init(path: "/opt/homebrew/bin/claude", found: true))

    private func with(folder: Readiness.OutputFolder? = nil, model: Readiness.Model? = nil, claude: Readiness.Claude? = nil) -> Readiness {
        Readiness(outputFolder: folder ?? ok.outputFolder, model: model ?? ok.model, claude: claude ?? ok.claude)
    }

    @Test func isCompleteNeedsAllThree() {
        #expect(ok.isComplete)
        #expect(!with(model: .downloading("base", fraction: 0.5)).isComplete)
        #expect(!with(claude: .init(path: nil, found: false)).isComplete)
        #expect(!with(folder: .init(path: "/x", available: false)).isComplete)
    }

    @Test func readyRowsShowPathOnly() {
        #expect(ReadinessPresentation.rows(ok, home: home) == [
            ReadinessRow(item: .outputFolder, title: "保存先", status: "~/Documents/AutoNote", ready: true, band: "", actions: []),
            ReadinessRow(item: .model, title: "文字起こしモデル（whisper base）", status: "", ready: true, band: "", actions: []),
            ReadinessRow(item: .claude, title: "議事録の作成（Claude Code）", status: "", ready: true, band: "", actions: [])])
        #expect(ReadinessPresentation.bands(ok, home: home).isEmpty)
    }

    @Test func downloadingRoundsDown() {
        let row = ReadinessPresentation.rows(with(model: .downloading("base", fraction: 0.429)), home: home)[1]
        #expect(row.title == "文字起こしモデル（whisper base）")
        #expect(row.status == "ダウンロード中 42 %")
        #expect(!row.ready)
        #expect(row.band == "文字起こしモデルをダウンロード中 42 %（終わるまでは Apple 音声入力で文字起こしします）")
        #expect(row.actions.isEmpty)
    }

    @Test func downloadingPercentIsClamped() {
        #expect(ReadinessPresentation.rows(with(model: .downloading("b", fraction: 1.7)), home: home)[1].status == "ダウンロード中 100 %")
        #expect(ReadinessPresentation.rows(with(model: .downloading("b", fraction: -0.2)), home: home)[1].status == "ダウンロード中 0 %")
    }

    @Test func failedModelOffersRetry() {
        let row = ReadinessPresentation.rows(with(model: .failed("base", reason: "ネットワークにつながりませんでした")), home: home)[1]
        #expect(row.title == "文字起こしモデル（whisper base）")
        #expect(row.status == "ダウンロードに失敗しました — ネットワークにつながりませんでした")
        #expect(row.band == "文字起こしモデルのダウンロードに失敗しました — ネットワークにつながりませんでした")
        #expect(!row.ready)
        #expect(row.actions == [.retryModelDownload])
    }

    @Test func noModelHasNoButton() {
        let row = ReadinessPresentation.rows(with(model: Readiness.Model.none), home: home)[1]
        #expect(row.title == "文字起こしモデル（whisper）")
        #expect(row.status == "ありません（Apple 音声入力で文字起こしします）")
        #expect(row.band == "文字起こしモデルがありません（Apple 音声入力で文字起こしします）")
        #expect(!row.ready)
        #expect(row.actions.isEmpty)
    }

    @Test func missingAndUncreatedFolder() {
        let missing = ReadinessPresentation.rows(with(folder: .init(path: "/Volumes/Vault", available: false)), home: home)[0]
        #expect(missing.title == "保存先")
        #expect(missing.status == "/Volumes/Vault が見つかりません")
        #expect(missing.band == "保存先 /Volumes/Vault が見つかりません")
        #expect(!missing.ready)
        #expect(missing.actions == [.changeOutputFolder])
        let uncreated = ReadinessPresentation.rows(with(folder: .init(path: "", available: false)), home: home)[0]
        #expect(uncreated.status == "作れませんでした")
        #expect(uncreated.band == "保存先を作れませんでした")
        #expect(uncreated.actions == [.changeOutputFolder])
    }

    @Test func claudeMissingOffersGuideAndRetry() {
        let row = ReadinessPresentation.rows(with(claude: .init(path: nil, found: false)), home: home)[2]
        #expect(row.title == "議事録の作成（Claude Code）")
        #expect(row.status == "見つかりません")
        #expect(row.band == "議事録の作成に Claude Code が要ります")
        #expect(!row.ready)
        #expect(row.actions == [.installGuide, .redetectClaude])
    }

    @Test func bandsAreOnlyUnreadyInOrder() {
        let r = with(model: .downloading("base", fraction: 0.1), claude: .init(path: nil, found: false))
        #expect(ReadinessPresentation.bands(r, home: home).map(\.item) == [.model, .claude])
    }

    @Test func abbreviateOnlyHomePrefix() {
        #expect(ReadinessPresentation.abbreviate("/Users/u/Documents/AutoNote", home: "/Users/u") == "~/Documents/AutoNote")
        #expect(ReadinessPresentation.abbreviate("/Users/u", home: "/Users/u") == "~")
        #expect(ReadinessPresentation.abbreviate("/Users/u2/x", home: "/Users/u") == "/Users/u2/x")
        #expect(ReadinessPresentation.abbreviate("/tmp/an-e2e.1/vault", home: "/Users/u") == "/tmp/an-e2e.1/vault")
    }

    @Test func actionTitles() {
        #expect(ReadinessPresentation.actionTitle(.changeOutputFolder) == "保存先を変える")
        #expect(ReadinessPresentation.actionTitle(.retryModelDownload) == "もう一度")
        #expect(ReadinessPresentation.actionTitle(.installGuide) == "入れ方を見る")
        #expect(ReadinessPresentation.actionTitle(.redetectClaude) == "もう一度探す")
    }
}

@Suite struct ReadinessFitTests {
    private let home = "/Users/u"
    private func ready(fit: [FitWarning]) -> Readiness {
        Readiness(outputFolder: .init(path: "/Users/u/Documents/AutoNote", available: true),
                  model: .installed("large-v3-turbo-q5_0"), claude: .init(path: "/opt/homebrew/bin/claude", found: true), fit: fit)
    }

    @Test func noWarningsKeepThreeRows() {
        #expect(ReadinessPresentation.rows(ready(fit: []), home: home).count == 3)
        #expect(Readiness.assumedReady.fit.isEmpty)
    }

    // 警告はモデルの行の直後に 1 行ずつ。完了扱いは変えない（録音はできる）が、帯には出る
    @Test func warningsAreRowsAfterTheModelAndBands() {
        let r = ready(fit: [.finalTooSlow(model: "large-v3-turbo-q5_0"), .liveTooSlow(model: "large-v3-turbo-q5_0")])
        #expect(r.isComplete)
        let rows = ReadinessPresentation.rows(r, home: home)
        #expect(rows.map(\.item) == [.outputFolder, .model, .fit(.finalTooSlow(model: "large-v3-turbo-q5_0")),
                                     .fit(.liveTooSlow(model: "large-v3-turbo-q5_0")), .claude])
        #expect(rows[2] == ReadinessRow(
            item: .fit(.finalTooSlow(model: "large-v3-turbo-q5_0")), title: "停止後の処理（whisper large-v3-turbo-q5_0）",
            status: "録音の 1〜1.3 倍の時間、CPU をほぼ使い切ります", ready: false,
            band: FitWarningPresentation.message(.finalTooSlow(model: "large-v3-turbo-q5_0")),
            actions: [.openTranscriptionSettings]))
        #expect(rows[3].title == "ライブ文字起こし（whisper large-v3-turbo-q5_0）")
        #expect(rows[3].status == "リアルタイムに追いつきません")
        #expect(ReadinessPresentation.bands(r, home: home).map(\.item)
            == [.fit(.finalTooSlow(model: "large-v3-turbo-q5_0")), .fit(.liveTooSlow(model: "large-v3-turbo-q5_0"))])
        #expect(ReadinessPresentation.actionTitle(.openTranscriptionSettings) == "文字起こしの設定を開く")
    }

    @Test func messagesNameTheModelAndTheRemedy() {
        #expect(FitWarningPresentation.message(.finalTooSlow(model: "large-v3-turbo"))
            == "この Mac（Intel）では whisper large-v3-turbo の確定版の文字起こしに録音と同じ〜1.3 倍の時間がかかり、そのあいだ CPU をほぼ使い切ります。small なら約半分の時間です")
        #expect(FitWarningPresentation.message(.finalLowMemory(model: "large-v3-turbo"))
            == "この Mac のメモリでは whisper large-v3-turbo の処理中にメモリが足りず、スワップが増えます（16 GB 以上を推奨）。large-v3-turbo-q5_0 なら同じ精度でメモリは約半分です")
        #expect(FitWarningPresentation.message(.liveTooSlow(model: "large-v3-turbo-q5_0"))
            == "この Mac（Intel）では whisper large-v3-turbo-q5_0 のライブ文字起こしがリアルタイムに追いつきません（確定版の 4 スレッドでも録音の 1.31 倍かかった実測があります）。リアルタイムは Apple の音声入力を推奨します")
        let memoryRow = ReadinessPresentation.rows(ready(fit: [.finalLowMemory(model: "large-v3-turbo")]), home: home)[2]
        #expect(memoryRow.title == "停止後の処理（whisper large-v3-turbo）")
        #expect(memoryRow.status == "メモリが足りずスワップが増えます")
    }
}
