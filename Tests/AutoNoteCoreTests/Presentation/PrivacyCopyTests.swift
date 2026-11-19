import Testing
import AutoNoteCore

@Suite struct PrivacyCopyTests {
    @Test func externalNoticeMentionsLiveSummary() {
        #expect(PrivacyCopy.externalNotice == "音声・文字起こし・議事録はこの Mac に保存します。外部へ送るのは、議事録を作るときに Claude Code へ渡す文字起こしテキスト（全文、辞書の用語、ブックマーク）だけで、音声は送りません。リアルタイム要約をオンにすると、録音中も確定した発話のテキストと、書いておいた「聞きたいこと」を Claude Code へ送ります。自動アップデートがオンのときは、1 日に 1 回 GitHub に最新版を問い合わせ、新しい版があればダウンロードします。問い合わせは通常の HTTP 要求だけで、録音・文字起こし・設定は送りません。")
    }

    @Test func liveSummaryNoteSaysWhatIsSent() {
        #expect(PrivacyCopy.liveSummaryNote == "オンにすると、録音中に確定した発話のテキストと「聞きたいこと」を更新間隔ごとに Claude Code へ送り、いまの話題・聞きたいことを聞けたか・宿題・決定事項を録音画面の右側に出します。議事録の作成と同じ Claude の利用枠を使います。オフのときは「聞きたいこと」も送りません。")
    }

    @Test func autoUpdateNoteSaysWhatIsSentAndWhen() {
        #expect(PrivacyCopy.autoUpdateNote == "オンにすると、1 日に 1 回 GitHub（このアプリのリリース）に最新版を問い合わせ、新しい版があればダウンロードし、署名がこのアプリと同じことを確かめてから、録音・議事録の作成・翻訳をしていないときに入れ替えて再起動します。問い合わせで送るのは通常の HTTP 要求だけです。")
    }

    /// The copy promises "nothing but the request": the request carries the app name alone, no version or machine.
    @Test func updateRequestUserAgentIsTheAppNameOnly() {
        #expect(UpdateURLPolicy.userAgent == "AutoNote")
    }
}
