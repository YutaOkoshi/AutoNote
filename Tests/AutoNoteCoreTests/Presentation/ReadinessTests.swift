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
