# 初回起動から議事録が開くまで — 設計（計画 07 の種）

日付: 2026-10-27　対象: plan-06 ブランチ（HEAD 1913eb7）以降　根拠: `docs/superpowers/research/2026-10-27-ux-audit/README.md` の P1-1〜P1-7

## 意図

AutoNote を初めて入れた人が、**説明を読まずに、録音を止めたら議事録が開いている**ところまで行けるようにする。監査では、録音の開始と停止は迷わないが、既定の設定では議事録が作れず（保存先なし・確定版エンジンなし）、失敗しても理由が出ない、という形で導線が切れていた。被験者 2 名とも議事録には辿り着けなかった。

## ゴール

- 初回起動 → 同意 → 録音 → 停止 → 議事録が自動で開く、を利用者の設定なしで通す（成功基準: 被験者テスト課題 3 を 2 名とも完遂）。
- 準備（保存先・文字起こしモデル・Claude Code）の状態と、足りないときの次の一手が、窓の中に見える。
- 録音中に「音を拾えている」ことが見える。
- 失敗は「何が・なぜ・次に何をするか」を同じ場所に出す。内部名は出さない。

## 非ゴール

- 監査 P2 の項目（設定の保存ボタン廃止、英語の内部メッセージの訳、一般タブの整理、アプリアイコンと ja.lproj、権限要求のタイミング）。別計画。
- 新しい要約器。Claude Code が無い Mac では議事録は作らず、入れ方へ導くだけ（利用者の決定）。
- ライブ文字起こしエンジンの変更。

## アンチゴール（できても失敗）

- 準備が終わるまで録音を待たせる。録音はいつでも始められ、足りないものは後から埋まる。
- 勝手に録音を始める。
- E2E や `AUTONOTE_DATA_DIR` 環境で、利用者の `~/Documents` を触る、150 MB をダウンロードする。
- 通知を増やす。議事録完了の通知は今のまま 1 通。

## 決めたこと（利用者の決定）

1. **同意 OK のあと**: メインウィンドウを開く。会議 0 件の空状態に、入口の案内・準備の状態・「録音を開始」ボタンを載せる（モックアップ B 案）。
2. **確定版の文字起こし**: 初回起動で whisper `base` を裏でダウンロードする。終わるまでは Apple 音声入力（ライブ）の文字起こしで議事録を作る。
3. **要約器**: Claude Code は前提条件。無ければ「入れ方を見る」「もう一度探す」の導線だけ出す。
4. **保存先**: 初回に `~/Documents/AutoNote` を自動で作ってそこに書く。Obsidian の Vault にしたい人は後から設定で変える。
5. **流れの各場面の文言と要素**: モックアップ `flow-states` のとおり（下の §画面 に転記）。

## 画面（決めた形）

### 0. 同意ウィンドウ
今のまま（「録音は相手の同意を得て行ってください」＋ OK）。OK で `consentNoticeShown = true` を保存し、**メインウィンドウを開く**（`AppShell.open(mainWindowID)`）。その後のマイク許可要求は今の順序（起動項目 5）のまま。

### 1. メインウィンドウ: ツールバー
- 左ペイン上のサイドバー切替はそのまま。右の取り込みアイコンの**左**に主ボタンを置く:
  - 待機中: `● 録音を開始`（`.borderedProminent`、`keyboardShortcut` 表記は付けない。ホットキーはメニュー側に出す）
  - 録音中: `■ 停止`（破壊的でない。確認なし）
  - 一時停止中: `■ 停止` と `▶ 再開`
  - カウントダウン中: `取り消す`
- 動作は `AppModel.perform(.start / .stop / .resume / .cancelCountdown)`。

### 2. 空状態（会議 0 件）と準備カード
右ペインが会議 0 件のとき:

```
        〰️
録音はメニューバーの 〰️ か、上の「録音を開始」から
止めると文字起こしと議事録が自動でできます。

保存先  ~/Documents/AutoNote                    ✓
文字起こしモデル（whisper base）    ダウンロード中 42 %
議事録の作成（Claude Code）   見つかりません — 入れ方を見る · もう一度探す
```

- 「音声ファイルをここへドラッグすると取り込めます」は 1 行目の下に小さく残す。
- **準備カード**（3 行）は空状態の下部に常に出す。会議が 1 件以上あるときは、**準備できていない行があるときだけ**、既存のバナー（`StatusHeader`）の形で 1 行ずつ出す:
  - 保存先: 「保存先 `<パス>` が見つかりません」［保存先を変える］ → 設定の一般タブ
  - モデル: 「文字起こしモデルをダウンロード中 42 %（終わるまでは Apple 音声入力で文字起こしします）」ボタン無し。失敗時: 「文字起こしモデルのダウンロードに失敗しました — `<理由 1 文>`」［もう一度］
  - Claude Code: 「議事録の作成に Claude Code が要ります」［入れ方を見る］［もう一度探す］
- 各行の状態は `AppModel.readiness: Readiness`（下の §モデル）から描く。

### 3. 録音中
ヘッダ（`StatusHeader` の録音帯）: `● 録音中 0:18  ▁▃▅▂▄  MacBook Pro のマイク`
- メーター: 直近 1 秒のピーク dBFS を 5 段のバーで。トラックが 2 本（マイク＋システム音声）なら大きい方。
- 10 秒以上ピークが −60 dBFS 未満なら、メーターの右に「音を拾えていません」。復帰したら消す。既存の `SilenceWarning`（マイク 15 秒・システム音声 60 秒の警告）とは別の、短い目安。
- 本文: 既存の `LiveTranscriptView`。発話がまだ無いときは中央に「聞き取り中…」（今は白紙）。

### 4. 停止直後 → 処理中
- 停止した瞬間、緑の帯「✓ 録音を保存しました（4 分 12 秒）」を 5 秒出す。
- 右ペイン（既存 `ProcessingDetailView`）の見出しを段階名にする: 「文字起こし中…」「議事録を作成中…」「保存中…」。文字起こし中は右に補足「Apple 音声入力（whisper はダウンロード中）」または「whisper base」。
- 本文に 1 文: 「文字起こし → 議事録の作成 → 保存 の順に進みます。終わると議事録がここに開きます。」
- **1 分未満**: 帯を「32 秒の録音です。1 分未満なので自動では処理しません。文字起こしと議事録を作りますか？」［作る］［削除］にする（モックの「議事録は作りません」は処理の実態と合わないので、この文言に差し替えた。Lead の判断）。一覧の行の長さは 1 分未満なら「32 秒」、以上は今のまま「4 分」。帯と詳細ビューの二重表示は帯だけにする。

### 5. できた（自動で開く）
- `.minutesGenerated` になった会議が **この起動中に録音・停止した会議** なら、メインウィンドウを開いて（閉じていれば開く、他アプリの前面には出ない: `NSApp.activate` はしない）その会議を選択する。取り込み・再生成・再実行では自動で開かない。
- 完了ビューの先頭に緑の帯「✓ 議事録を保存しました — `~/Documents/AutoNote/2026-10-27_1400_発売準備会議.md`」を出す（この会議を次に選び直すまで）。
- ツールバーに「Finder で表示」（`NSWorkspace.activateFileViewerSelecting`）を常設。「Obsidian で開く」は Obsidian が無ければ**非表示**（今は薄表示で理由なし）。
- 通知は今のまま 1 通（「議事録ができました」→ タップで同じ画面）。

### 6. 失敗
右ペインの帯（赤）に `何が — なぜ`、右にボタン 1〜2 個。本文は、文字起こしがあればそれを表示（「文字起こしはできています。議事録は再実行で作れます」）。

| 失敗 | 帯の文言 | ボタン |
|---|---|---|
| `claude_not_found`（`summaryFailure`） | 議事録を作れませんでした — Claude Code（claude）が見つかりません | ［入れ方を見る］［もう一度探して再実行］ |
| `not_logged_in`（`summaryFailure`） | 議事録を作れませんでした — Claude Code にログインしていません | ［ターミナルで `claude` を開く手順を見る］［再実行］（既存の通知文言に合わせる） |
| 文字起こし: エンジンなし＋ライブも空 | 音声を聞き取れませんでした — 録音に声が入っていないか、マイクが拾えていません | ［録音を聞く］（Finder で音声を表示）［削除］ |
| 保存: 書けない（再試行待ち） | 保存先に書けないので待っています — `<パス>` | ［保存先を変える］ |
| 上記以外 | `<段階名>に失敗しました — <理由を 1 文に丸めたもの>` | ［再実行］ |

- **失敗の出どころは 2 つ**（Lead の判断）: (a) ジョブの失敗 `QueueItemDTO.message`（= `job.lastError`、`stage` 付き）、(b) ジョブは完了したが要約が失敗して `.transcriptOnly` になった会議の `summaryFailure`（`claude_not_found: <path>` / `not_logged_in`）。`FailureExplanation.make(source:)` は `enum Source { case job(stage: String, reason: String?), summary(String?) }` を受ける。一覧の行は今のまま（ジョブ失敗=「失敗」、要約失敗=「文字起こしのみ」）で、帯が理由を説明する。
- **保存先に書けないとき**はジョブは失敗ではなく再試行待ち（今の `WriteVaultStage` の意味を変えない）。帯は黄色で「保存先に書けないので待っています — `<パス>`」［保存先を変える］。`notBefore != nil` の「再試行待ち」行がこれに当たる。
- 内部名（`TranscriptionError`、`final_transcription_failed:`、`claude_not_found:`）は画面に出さない。`autonote status --json` と `logs/` には今のまま残す。
- 一覧の行は今のまま「失敗」（赤）。

### 7. メニューバーのメニュー
```
録音開始                 ⌃⌥R
──────────────
⚠ 保存先が見つかりません — 設定を開く…   ← 押せる。準備できていないときだけ
⚠ 議事録の作成に Claude Code が要ります…  ← 押せる。空状態の準備カードと同じ導線
──────────────
ウィンドウを開く
最新の議事録を開く（まだありません）        ← 無効のときはこの表記
設定…                    ⌘,
──────────────
開発 ▸
──────────────
終了                     ⌘Q
```
- 「録音開始」「停止」「一時停止」にホットキー表記（設定のショートカットタブの値）。
- 「出力フォルダ」の語は全画面で「**保存先**」に統一（設定の一般タブの見出しも）。
- モデルのダウンロード中はメニューに出さない（窓で見る）。

### 8. 設定
- 「設定を開く」「保存先を変える」「設定…」は**一般タブ**で開く（`TabView(selection:)` を `AppShell.settingsTab` に束ね、開く側が指定。保存はしない）。
- 一般タブの「保存先」欄に、空のときは既定パスをプレースホルダで示す（`~/Documents/AutoNote`）。保存先を空で保存したら既定に戻す（nil にしない）。

## モデル・ポート（決めたこと）

### Readiness
`AutoNoteCore/Presentation/Readiness.swift`
```swift
public struct Readiness: Sendable, Equatable {
    public enum Model: Sendable, Equatable { case installed(String), downloading(String, fraction: Double), failed(String, reason: String), none }
    public struct OutputFolder: Sendable, Equatable { public var path: String; public var available: Bool }
    public struct Claude: Sendable, Equatable { public var path: String?; public var found: Bool }
    public var outputFolder: OutputFolder
    public var model: Model
    public var claude: Claude
    public var isComplete: Bool { outputFolder.available && claude.found && (if case .installed = model { true } else { false }) }
}
```
- `AppModel.readiness` を追加。`refresh()` で保存先と claude を読み直す。モデルは `ReadinessPort.updates()` の `AsyncStream<Readiness.Model>` で更新する（`ModelManager.download(_:progress:)` のコールバックをポートの live 実装が stream に変える。`ModelManager` 自体に stream は無い）。
- `AppPorts` に `readiness: any ReadinessPort`（`current()`, `updates()`, `redetectClaude()`, `retryModelDownload()`, `installGuide()` = 公式インストール手順の URL を `opener` で開く）。

### 既定値の確定（起動項目に追加）
`AppDelegate` の起動順で、`AppEnvironment.make` の前に `FirstRunDefaults.apply(settings:paths:isDataDirectoryOverridden:)`:
- `outputFolder == nil || ""` → 既定パスを作って保存。既定パス: 通常は `~/Documents/AutoNote`、`AUTONOTE_DATA_DIR` 配下で動いているときは `<data dir>/vault`（E2E・開発で `~/Documents` を触らない。X22 と同じ考え方）。作成に失敗したら nil のままにして、準備カードが「保存先を作れませんでした」［保存先を変える］を出す。
- whisper: `ModelManager.installed()` に batch で使えるモデルが 1 つも無く、`AUTONOTE_DATA_DIR` 配下でなければ `download("base")` を開始（二重起動は `ModelManager` が畳む）。進捗は `Readiness.model` へ。失敗しても起動は続く。`AUTONOTE_DATA_DIR` 配下では開始しない（E2E は `Readiness.model == .none` を期待値にする）。
- claude: 既存の `ClaudeLocator.fillDefaultPath` をそのまま使う。`Readiness.claude` は `claudePath` が実行可能ファイルかで判定。

### 確定版エンジンの代用
今は確定版エンジンが**ステージを作るとき**に 1 回だけ決まり（`AppEnvironment` の `StageBuilder`、使えるものが無ければ large-v3-turbo に固定）、作り直しは設定保存時だけ。これだと base を入れ終えても切り替わらない。**実行のたびに決める**に変える（Lead の判断。処理中のジョブを止めずに済み、Core 側で閉じる）:
- `TranscribeStage` は runner ではなく `resolveBatch: @Sendable (Language) async -> (any BatchTranscriber)?` を受け取り、ジョブごとに呼ぶ。live 実装は `EngineCatalog.resolve(role: .batch)` + `TranscriberFactory.makeBatch`。
- 「使えるエンジンなし」（closure が nil）なら、失敗を記録せずに live.json を確定版として書き出す。エンジン名は「Apple 音声入力（リアルタイム版）」（既存の `fallbackEngineLabel` の文言「確定版の失敗により…」は、本当に失敗したときだけ）。
- live.json に発話が 0 件なら `StageError.failed(reason: "no_speech")` → 失敗表 3 行目。
- `base` が入ったあとは `resolve` が自動で whisper を選ぶ（`finalEngine == nil` の既定の動き）。`large-v3-turbo` を後から入れれば既定どおりそれが優先される。

### 入力レベル
- `RecorderPort` に `levels() async -> [TrackLevel]`（`track`, `peakDBFS` 直近 1 秒）を追加。今の統計は開始以来の最大値しか無い（`TrackStatistics.peakDBFS`、`SilenceMonitor.micPeak`）ので、**両トラックに直近 1 秒窓のピークを新しく持たせる**（`RecordingPipeline` のチャンク処理で更新。1 秒ごとにリセット）。
- `AppModel` の 1 秒 tick（既存 `updateElapsed`）で読む。イベントの push は増やさない（主スレッドの負荷を増やさない。2026-10-27 の P0 の教訓）。

### 失敗の説明
`AutoNoteCore/Presentation/FailureExplanation.swift`
```swift
public struct FailureExplanation: Sendable, Equatable {
    public var what: String; public var why: String; public var actions: [Action]
    public enum Action: Sendable, Equatable { case installGuide, redetectClaudeAndRerun, rerun, openSystemSettings, revealAudio, delete, changeOutputFolder, loginGuide }
    public static func make(stage: String, reason: String?) -> FailureExplanation
}
```
- `QueueItemDTO.message`（= `job.lastError`）と `stage` から表を引く。純粋関数なので `Tests/AutoNoteCoreTests/Presentation/FailureExplanationTests.swift` で全行を固定する。

### 自動オープン
- `AppModel` に `recordedThisSession: Set<MeetingID>`（`.started` イベントで追加）と `minutesReady: ((MeetingID, path: String)) -> Void` のフック。`AppEnvironment.relayQueueNotices` が `NoticeRelay.notices` から `.minutesGenerated(id)` を得たとき（`NoticeRelay` は純粋関数。呼ぶのは App 側）、`id` が集合にあれば `AppShell.open(mainWindowID)` → `model.selectedMeetingID = id` → `model.justSaved = (id, path)`（緑の帯の元）。
- 前面に出すかどうか: §画面 5 を参照（利用者の決定待ち → 決まり次第ここに転記）。
- `.minutesGenerated` の通知は今のとおり 1 通。

## 制約

- Swift 6.3 / swift-tools-version 6.2、既存のアーキテクチャ（`AppModel` は `@MainActor @Observable`、ポート越しに Core へ）。Core に AppKit を入れない。
- `MenuBarExtra` のラベルに `TimelineView` や毎フレーム更新を入れない（P0 の再発防止。E2E 06.7 が見張る）。
- 通知は `SystemUserNotifier` が唯一の送り手（X43）。新しい通知は増やさない。
- `AUTONOTE_DATA_DIR` 配下: `~/Documents` に触らない、モデルをダウンロードしない、ログイン項目に触らない（X22）。
- 既存 E2E 33 項目を壊さない。E2E 7 の起動は `settings.json` に `output_folder` が無い状態で行われるので、起動後に `<DATA>/vault` が作られ `settings.json` に書かれることを新しい項目で確かめる。
- 文言は日本語、内部識別子を画面に出さない。「保存先」に統一。

## 検証（計画の各タスクが満たすもの）

- 単体: `Readiness` の合成、`FirstRunDefaults`（nil → 既定パス、override 時は data dir 配下、作成失敗で nil）、`FailureExplanation` 全行、`TranscribeStage` の「エンジンなし→ライブ代用、発話 0→no_speech」、`MenuBarPresentation` の新しい項目と表記、短い録音の秒表示。
- E2E（`scripts/e2e-check.sh` に追加）: 07.1 起動後に `<DATA>/vault` と `settings.json` の `output_folder`、07.2 `Readiness.model == .none`（override 下でダウンロードしない）、07.3 メニューに「保存先が見つかりません」が**出ない**（既定パスがあるため）、07.4 `autonote status --json` の失敗 `message` が従来形式のまま（CLI 互換）。
- 実機（Lead が AX ツールで）: 新しいデータ領域で 同意 → 録音 90 秒（音声あり: `say` で読み上げ）→ 停止 → 議事録が自動で開く。Claude Code のパスを空にした状態で失敗帯の文言。
- 被験者テスト: `docs/superpowers/research/2026-10-27-ux-audit/zero-context-brief.md` を 2 名で再実行し、課題 3 を 2 名とも完遂。

## 作る人に任せること

- 準備カードと帯の正確なレイアウト（余白、アイコン。既存の `StatusHeader` の見た目に合わせる）。
- メーターの描画（5 段のバー、更新は 1 Hz）。
- 「入れ方を見る」の URL（Claude Code の公式インストール手順。実装時に現行の URL を確認する）。
- `ReadinessPort` の live 実装の置き場所（`LiveAdapters.swift` に倣う）。
- 緑の帯の消し方（5 秒タイマーか、次の操作まで）。
