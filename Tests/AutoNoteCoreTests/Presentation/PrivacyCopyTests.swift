import Testing
import AutoNoteCore

@Suite struct PrivacyCopyTests {
    /// The translation sends nothing out (spec 2026-11-19: 外部送信の説明は変わらない); the summaries are still made
    /// from the original and then translated on this Mac.
    @Test func translationNoteSaysNothingIsSentAndSummariesAreTranslatedAfterwards() {
        #expect(TranslationSettingsPresentation.privacyNote == "翻訳は Mac の中だけで行い、訳すために外へ送るものはありません（通信するのはモデルのダウンロードだけです）。ライブ要約と議事録は今までどおり原文から作り、できた要約をこの Mac で訳します。訳文を要約の材料にはしません。")
        #expect(TranslationSettingsPresentation.targetNote == "自動では、日本語の発話を英語に、英語の発話を日本語に訳します。訳文は文字起こしの各行に併記します。ライブ要約と議事録は会議の言語で作り、訳す先（自動では会議の言語の反対）へ訳して各項目の下に併記します（会議の画面の「訳文」で表示を切り替えられます）。")
        #expect(!PrivacyCopy.externalNotice.contains("翻訳"))
    }

    @Test func externalNoticeMentionsLiveSummary() {
        #expect(PrivacyCopy.externalNotice == "音声・文字起こし・議事録はこの Mac に保存します。外部へ送るのは、議事録を作るときに Claude Code へ渡す文字起こしテキスト（全文、辞書の用語、ブックマーク）だけで、音声は送りません。リアルタイム要約をオンにすると、録音中も確定した発話のテキストと、書いておいた「聞きたいこと」を Claude Code へ送ります。自動アップデートがオンのときは、1 日に 1 回 GitHub に最新版を問い合わせ、新しい版があればダウンロードします（つながらなかったときは 1 時間後から間隔を倍にしながら問い合わせ直し、最初の 1 日で最大 5 回です）。問い合わせは版・端末・言語の設定を含まない通常の HTTP 要求だけで、録音・文字起こし・設定は送りません。")
    }

    @Test func liveSummaryNoteSaysWhatIsSent() {
        #expect(PrivacyCopy.liveSummaryNote == "オンにすると、録音中に確定した発話のテキストと「聞きたいこと」を更新間隔ごとに Claude Code へ送り、いまの話題・聞きたいことを聞けたか・宿題・決定事項を録音画面の右側に出します。議事録の作成と同じ Claude の利用枠を使います。オフのときは「聞きたいこと」も送りません。")
    }

    @Test func autoUpdateNoteSaysWhatIsSentAndWhen() {
        #expect(PrivacyCopy.autoUpdateNote == "オンにすると、1 日に 1 回 GitHub（このアプリのリリース）に最新版を問い合わせ（つながらなかったときは 1 時間後から間隔を倍にしながら問い合わせ直します）、新しい版があればダウンロードし、署名がこのアプリと同じことを確かめてから、録音・議事録の作成・翻訳・音声の取り込み・モデルのダウンロード・Automation をしていないときに入れ替えて再起動します。問い合わせで送るのは、版・端末・言語の設定を含まない通常の HTTP 要求だけです。")
    }

    /// The copy promises "nothing but the request": the request carries the app name alone, no version or machine.
    @Test func updateRequestUserAgentIsTheAppNameOnly() {
        #expect(UpdateURLPolicy.userAgent == "AutoNote")
        // 「言語の設定を含まない」: a fixed language, never the Mac's.
        #expect(UpdateURLPolicy.acceptLanguage == "en")
        // 「最初の 1 日で最大 5 回」: 0, 1, 3, 7 and 15 hours, the next after 31.
        var at = 0.0, tries = [0.0]
        for n in 1...5 { at += UpdateSchedule.retryDelay(failures: n); tries.append(at) }
        #expect(tries.filter { $0 < 86_400 }.count == 5)
    }
}
