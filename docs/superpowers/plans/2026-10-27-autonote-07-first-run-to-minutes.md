# AutoNote 計画 07: 初回起動から議事録が開くまで Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 初めて入れた人が説明を読まずに、同意 → 録音 → 停止 → 議事録が開いている、まで行けるようにする（監査 P1-1〜P1-7）。

**Architecture:** 判断はすべて `AutoNoteCore` の純粋な型（`Readiness`・`ReadinessPresentation`・`FirstRunDefaults`・`FailureExplanation`・`FlowPresentation`・`InputLevelTracker`）と `AppModel` に置き、Swift Testing で固定する。外の世界（設定・モデル・claude・URL を開く）は新しいポート `ReadinessPort` 越しに読み、その live 実装 `LiveReadinessPort` も Core に置く。確定版エンジンは `TranscribeStage` がジョブごとに決め、使えるエンジンが無ければライブの文字起こしを確定版にする。`AutoNoteApp` は起動順・配線・画面だけを足す。

**Tech Stack:** Swift 6.3 / swift-tools-version 6.2 / SwiftUI（`MenuBarExtra`・`Window`・`Settings`）/ Observation / Swift Testing / bash（`scripts/e2e-check.sh`）/ osascript（GUI の確認）

**Spec:** `docs/superpowers/specs/2026-10-27-first-run-to-minutes-design.md`（binding）。背景: `docs/superpowers/research/2026-10-27-ux-audit/README.md`。直前の計画と裁定: `docs/superpowers/plans/2026-10-25-autonote-06-ui-cli-automations.md`、`docs/superpowers/plans/2026-10-26-autonote-implementation-progress.md` の「計画 06」節

## Global Constraints

- Swift 6.3 / `swift-tools-version: 6.2` / `swiftLanguageModes: [.v6]`。最低 OS は macOS 26.0（`Package.swift` は変えない）
- `AutoNoteCore` に AppKit・SwiftUI を入れない。App から使う Core の型・関数は `public`
- `AppModel` は `@MainActor @Observable`。画面はポート越しに Core へ（具体型に触るのは `AppEnvironment.make` だけ。X36 の例外は維持）
- `MenuBarExtra` のラベルに `TimelineView` や毎フレーム更新を入れない（2026-10-27 の P0。E2E 06.7 が見張る）。入力レベルは既存の 1 秒 tick（`AppModel.updateElapsed`）で読み、イベントの push を増やさない
- 通知は `SystemUserNotifier` が唯一の送り手（X43）。新しい通知を増やさない。議事録完了の通知は今のまま 1 通
- `AUTONOTE_DATA_DIR` 配下: `~/Documents` に触らない、モデルをダウンロードしない、ログイン項目に触らない（X22）
- 既存 E2E 34 項目（33 関数。項目 7 が 7 と 7b を出す。06.7 を含む）を壊さない。E2E 7 は `settings.json` に `output_folder` が無い状態で起動する
- 文言は日本語。内部識別子（`TranscriptionError`、`final_transcription_failed:`、`claude_not_found:` など）を画面に出さない。`autonote status --json` と `logs/` には今のまま残す。画面上の「出力フォルダ」は「**保存先**」に統一（CLI の人向け出力は変えない）
- 録音はいつでも始められる（準備が終わるまで待たせない）。勝手に録音を始めない
- `QueueHolder` のキューは起動後に差し替えない（X19）。設定変更は `queue.register(_:)` でステージを入れ替える
- 開発 メニューと `DevChecks.swift` は消さない（X11）
- コミットは英語の Conventional Commits、タスクごと。push はしない。トレーラーは実装者が付ける
- 実装者はタスク完了前に `scripts/e2e-check.sh`（Core だけのタスクは `--quick` 可）を回し、結果を報告に含める
- `AutoNoteCore.Settings` と `SwiftUI.Settings` は両方 import する所で修飾する（X12）

## 前提の相違

設計書と既存コードが合わない点。設計書は編集せず、意図を優先して次のとおり決める。

1. **`FailureExplanation` の入口**: 設計書のコード片は `make(stage:reason:)`、本文（Lead の判断）は `make(source:)` と `enum Source { case job(stage:reason:), summary(String?) }`。本文を採る。さらに「再試行待ち」（黄色の帯）を区別するため `job` に `waiting: Bool = false` を足し、帯に保存先のパスを入れるため `make(_:outputFolderPath:)` とし、帯の色のため `tone: Tone { failure, waiting }` を持たせる（追加のみ）。
2. **`TranscribeStage` の closure の型**: 設計書は `resolveBatch: (Language) async -> (any BatchTranscriber)?`。`TranscribeStage` は `FinalTranscriptionRunner`（`engineName`・`paths`・`gate` が要る）を通して `transcript_engine` を書くので、closure は `resolveRunner: @Sendable (Language) async -> FinalTranscriptionRunner?` にする。意味（ジョブごとに決める、nil ならライブで代用）は同じ。`init(runner:)` と `standardStages(runner:)` は残し、`{ _ in runner }` に委ねる（`DevSummarize` と既存テストを壊さない）。
3. **`summaryFailure` の形**: `QueueItemDTO.summaryFailure` は `SummaryFailureKind` の rawValue だけ（`claude_not_found`）で、`Job.summaryFailure` の `claude_not_found: <path>` は画面まで来ない。`Source.summary` は `SummaryFailureKind.of(_:)` で両方の形を読む。帯の文言はパスを使わないので不足しない。
4. **秒の長さ**: `MeetingRow` は `durationMinutes`（四捨五入の分）しか持たず「32 秒」を出せない。`MeetingRow.durationSeconds: Int?` を足す（`autonote list --json` に `duration_seconds` が増える。追加のみで既存キーは変えない）。
5. **短い録音の帯**: 帯（`model.prompts`）は通知を出したときにしか作られず、再起動すると消える。設計書どおり詳細ビューのボタンを消すと答える場所が無くなるので、`.tooShort` の行から帯を作る（I1 の上書き確認と同じ考え方）。通知の文言とボタン（「文字起こしする」「破棄」）は変えない。帯だけ新しい文言と［作る］［削除］。
6. **停止直後の選択**: 設計書 §4 は停止後の右ペインに `ProcessingDetailView` が出る前提だが、今は停止しても何も選ばれない。`.stopped` のとき何も選ばれていなければ、その会議を選ぶ（ウィンドウは開かない・前面にしない）。
7. **`minutesReady` フック**: 設計書は `AppModel` のフック。判断（この起動中に録音したか、窓が開いているか、編集中の別の会議を奪わないか）をテストできるよう、`AppModel.minutesReady(_:path:windowOpen:) -> Bool` のメソッドにし、`AppEnvironment.relayQueueNotices` が呼ぶ。
8. **URL を開く経路**: `WorkspaceOpener` は Obsidian が入っていると渡された URL を必ず `obsidian://` にする。`ReadinessPort.installGuide()` が `opener` で https を開くと Obsidian に飛ぶ。Core に `ObsidianLink.target(for:obsidianInstalled:)` を足し、ファイル以外の URL はそのまま開く。
9. **モデルの進捗**: `ModelManager.download(_:progress:)` の進捗は受信のたびに呼ばれる。そのまま stream に流すと主スレッドが詰まる（P0 と同じ形）。`LiveReadinessPort` は整数 % が変わったときだけ流す。
10. **既存の保存先の帯**: StatusHeader の「出力フォルダが未設定です／見つかりません」（X35）とメニューの `.status("出力フォルダが見つかりません")` は、準備の帯・メニューの ⚠ 項目に置き換える（二重に出さない）。
11. **空状態の「録音を開始」**: 利用者の決定 1 は「空状態にボタン」、§2 のモックは「上の「録音を開始」から」でボタンはツールバー（§1）。ツールバーのボタンが空状態の真上にあるので、空状態の中には重ねて置かない。
12. **`Readiness.model == .none` の帯**: 設計書に文言が無い（`AUTONOTE_DATA_DIR` 配下で必ずこの状態）。「文字起こしモデルがありません（Apple 音声入力で文字起こしします）」、ボタン無し。
13. **ログインの手順**: 設計書は［ターミナルで `claude` を開く手順を見る］の行き先を決めていない。URL を持たず、既存の通知文と同じ内容の手順を `NSAlert` で出す（`FailureExplanation.loginSteps`）。
14. **読み込み前の `readiness`**: `AppModel.run()` が読むまでの初期値は `Readiness.assumedReady`（保存先あり・claude あり・モデル `.none`）。起動直後に偽の警告を一瞬出さない。

## Review Focus

設計書から読み取れるが、素直に作ると誰のテストにも引っかからず、利用者が踏みやすいもの。各行のテストは担当タスクに入れてある。

1. 150 MB のダウンロード進捗が受信のたびに `AppModel` へ流れ、主スレッドが回り続けてウィンドウが固まる（P0 と同じ形）。整数 % が変わったときだけ流す（Task 7 `progressIsYieldedPerWholePercent`）
2. 別の会議の議事録を編集中に、録音した会議の議事録ができて選択が移り、未保存の編集が消える。編集中（選択中の行が `.minutesGenerated`）は選択を奪わない（Task 8 `minutesReadyDoesNotStealEditorSelection`）
3. 短すぎる録音のあとアプリを再起動すると帯が無く、詳細ビューにもボタンが無いので答えられない。帯は `.tooShort` の行から作る（Task 8 `tooShortPromptsFollowRows`）
4. 「入れ方を見る」の https が、Obsidian の入った Mac では Obsidian に渡されて開かない（Task 4 `webURLIsNeverSentToObsidian`）
5. 一時停止やブックマークをしただけでほぼ無言の録音は、`live.json` に印（`── ブックマーク ──` など）だけが残る。印を発話と数えて空の議事録を作らず、「音声を聞き取れませんでした」にする（Task 5 `markersOnlyIsNoSpeech`）

## 設計書 → タスク対応表

| 設計書 | 実装 | 検証 |
|---|---|---|
| §画面 0 同意 OK でメインウィンドウを開く | Task 9 | Task 9 Step 5（osascript） |
| §画面 1 ツールバーの主ボタン | Task 4（`MainToolbar`）・Task 10 | Task 4 `toolbarActionsByState`、Task 10 Step 3 |
| §画面 2 空状態と準備カード、会議ありのときの帯 | Task 1（文言）・Task 10 | Task 1 全テスト、Task 10 Step 3 |
| §画面 3 録音中（メーター、音を拾えていません、聞き取り中…） | Task 6・Task 8・Task 10 | Task 6 `quietAfterTenSilentTicks` ほか、Task 8 `inputLevelTicksWhileRecording` |
| §画面 4 停止直後の帯、段階名の見出し、1 分未満の帯、一覧の秒表示 | Task 4（文言）・Task 8（帯と選択）・Task 11 | Task 4 `durationText*`・`shortRecordingBand`・`processingHeadings`、Task 8 `stopped*` |
| §画面 5 自動で選ぶ、緑の帯、Finder で表示、Obsidian を隠す | Task 8・Task 9・Task 11 | Task 8 `minutesReady*`・`justSavedClearsOnReselect`、Task 11 Step 3 |
| §画面 6 失敗の帯（表の 5 行と再試行待ち） | Task 3・Task 11 | Task 3 全テスト |
| §画面 7 メニュー（⚠ 項目、ホットキー表記、まだありません、保存先の語） | Task 4・Task 12 | Task 4 `readinessIssuesInMenu`・`shortcutsFollowSettings`、E2E 07.3 |
| §画面 8 設定を一般タブで開く、保存先のプレースホルダ、空なら既定 | Task 2（`outputFolder(forInput:)`）・Task 12 | Task 2 `blankInputMapsToDefault`、Task 12 Step 3 |
| §モデル `Readiness` / `AppModel.readiness` / `ReadinessPort` | Task 1・Task 7・Task 8 | Task 7・Task 8 の各テスト |
| §既定値の確定（保存先・whisper base・claude） | Task 2・Task 7・Task 9 | Task 2 全テスト、Task 7 `overrideNeverDownloads`、E2E 07.1・07.2 |
| §確定版エンジンの代用（ジョブごと、ライブ代用、no_speech） | Task 5・Task 9 | Task 5 全テスト |
| §入力レベル（`RecorderPort.levels()`、直近 1 秒） | Task 6・Task 8 | Task 6 全テスト |
| §失敗の説明（`FailureExplanation`） | Task 3 | Task 3 全テスト |
| §自動オープン（`recordedThisSession`、窓が開いているときだけ） | Task 8・Task 9 | Task 8 `minutesReady*` |
| §検証 単体（Readiness、FirstRunDefaults、FailureExplanation 全行、TranscribeStage、MenuBarPresentation、秒表示） | Task 1・2・3・5・4・4 | 各タスクの Step 4 |
| §検証 E2E 07.1〜07.4 | Task 9（07.1・07.2・07.4）・Task 12（07.3） | `scripts/e2e-check.sh` |
| §検証 実機（say で 90 秒 → 自動で開く、claude 空で失敗帯） | Task 12 Step 5（実装者が osascript で一度）。受け入れは Lead | — |
| §検証 被験者テスト（課題 3 を 2 名とも完遂） | 計画の外（Lead が全タスク後に `zero-context-brief.md` で実施） | — |

## ファイル構成

- Core（新規）: `Presentation/Readiness.swift`（Task 1）、`Storage/FirstRunDefaults.swift`（Task 2）、`Presentation/FailureExplanation.swift`（Task 3）、`Presentation/FlowPresentation.swift`（Task 4）、`Audio/RecentPeakWindow.swift`・`Presentation/InputLevel.swift`（Task 6）、`Presentation/ReadinessPort.swift`（Task 7。プロトコルと `LiveReadinessPort`）
- Core（変更）: `MenuBarPresentation.swift`・`KeyCombo.swift`・`NoticeContent.swift`・`LiveAdapters.swift`・`MeetingListBuilder.swift`・`ObsidianLink.swift`・`IPC/WireTypes.swift`（Task 4）、`Minutes/Stages/TranscribeStage.swift`・`Minutes/PostProcessingPipeline.swift`・`Model/Utterance.swift`（Task 5）、`Audio/RecordingSession*.swift`・`Presentation/Ports.swift`・`LiveAdapters.swift`（Task 6・7）、`AppModel.swift`（Task 8）
- TestSupport: `FakePorts.swift`（Task 6 `FakeRecorderPort.setLevels`、Task 7 `FakeReadinessPort`）
- App: `AppDelegate.swift`・`AppEnvironment.swift`・`AppShell.swift`・`WorkspaceOpener.swift`（Task 9）、`MainWindow/*`（Task 10・11）、`MenuBarContent.swift`・`Settings/SettingsView.swift`・`Settings/GeneralTab.swift`（Task 12）
- E2E: `scripts/e2e-check.sh`、`Tests/Fixtures/queue/20261025-0930-c3d4.json`（Task 9・12）

---

### Task 1: `Readiness` と準備カードの文言

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/Readiness.swift`
- Test: `Tests/AutoNoteCoreTests/Presentation/ReadinessTests.swift`

**Interfaces:**
- Consumes: なし
- Produces:
  - `public struct Readiness: Sendable, Equatable`（設計書 §モデル のとおり: `enum Model { case installed(String), downloading(String, fraction: Double), failed(String, reason: String), none }`、`struct OutputFolder { path: String; available: Bool }`、`struct Claude { path: String?; found: Bool }`、`outputFolder`・`model`・`claude`、`isComplete`。各 struct に memberwise の `public init`）と `public static let assumedReady = Readiness(outputFolder: .init(path: "", available: true), model: .none, claude: .init(path: nil, found: true))`
  - `public struct ReadinessRow: Equatable, Sendable { enum Item { outputFolder, model, claude }; enum Action { changeOutputFolder, retryModelDownload, installGuide, redetectClaude }; var item: Item; var title: String; var status: String; var ready: Bool; var band: String; var actions: [Action] }`（memberwise の public init）
  - `public enum ReadinessPresentation { static func rows(_ r: Readiness, home: String) -> [ReadinessRow] /* 常に 3 行、保存先・モデル・Claude の順 */; static func bands(_ r: Readiness, home: String) -> [ReadinessRow] /* !ready の行だけ */; static func abbreviate(_ path: String, home: String) -> String; static func actionTitle(_ a: ReadinessRow.Action) -> String }`

- [ ] **Step 1: 失敗するテストを書く**

文言の表（`pct = Int((fraction * 100).rounded(.down))` を 0〜100 に丸める。`p` は `abbreviate(path, home:)`）:

| 状態 | title | status | ready | band | actions |
|---|---|---|---|---|---|
| 保存先 available | 保存先 | `p` | true | "" | [] |
| 保存先 !available・path 非空 | 保存先 | `p` が見つかりません | false | 保存先 `p` が見つかりません | [.changeOutputFolder] |
| 保存先 path 空 | 保存先 | 作れませんでした | false | 保存先を作れませんでした | [.changeOutputFolder] |
| `.installed(n)` | 文字起こしモデル（whisper `n`） | "" | true | "" | [] |
| `.downloading(n, f)` | 同上 | ダウンロード中 `pct` % | false | 文字起こしモデルをダウンロード中 `pct` %（終わるまでは Apple 音声入力で文字起こしします） | [] |
| `.failed(n, r)` | 同上 | ダウンロードに失敗しました — `r` | false | 文字起こしモデルのダウンロードに失敗しました — `r` | [.retryModelDownload] |
| `.none` | 文字起こしモデル（whisper） | ありません（Apple 音声入力で文字起こしします） | false | 文字起こしモデルがありません（Apple 音声入力で文字起こしします） | [] |
| claude found | 議事録の作成（Claude Code） | "" | true | "" | [] |
| claude !found | 同上 | 見つかりません | false | 議事録の作成に Claude Code が要ります | [.installGuide, .redetectClaude] |

```swift
private let home = "/Users/u"
private let ok = Readiness(outputFolder: .init(path: "/Users/u/Documents/AutoNote", available: true),
                           model: .installed("base"), claude: .init(path: "/opt/homebrew/bin/claude", found: true))
@Test func isCompleteNeedsAllThree()          // ok → true。model .downloading / claude.found false / outputFolder.available false のどれか 1 つで false
@Test func readyRowsShowPathOnly() {
    #expect(ReadinessPresentation.rows(ok, home: home) == [
        ReadinessRow(item: .outputFolder, title: "保存先", status: "~/Documents/AutoNote", ready: true, band: "", actions: []),
        ReadinessRow(item: .model, title: "文字起こしモデル（whisper base）", status: "", ready: true, band: "", actions: []),
        ReadinessRow(item: .claude, title: "議事録の作成（Claude Code）", status: "", ready: true, band: "", actions: [])])
    #expect(ReadinessPresentation.bands(ok, home: home).isEmpty)
}
@Test func downloadingRoundsDown()            // fraction 0.429 → status "ダウンロード中 42 %"、band は表のとおり、actions []
@Test func failedModelOffersRetry()           // .failed("base", reason: "ネットワークにつながりませんでした") → 表の status / band、[.retryModelDownload]
@Test func noModelHasNoButton()               // .none → 表の title / status / band、[]
@Test func missingAndUncreatedFolder()        // available false + "/Volumes/Vault" → band "保存先 /Volumes/Vault が見つかりません"; path "" → band "保存先を作れませんでした"; どちらも [.changeOutputFolder]
@Test func claudeMissingOffersGuideAndRetry() // found false → band "議事録の作成に Claude Code が要ります"、[.installGuide, .redetectClaude]
@Test func bandsAreOnlyUnreadyInOrder()       // 保存先 OK・モデル downloading・claude なし → bands の item == [.model, .claude]
@Test func abbreviateOnlyHomePrefix() {
    #expect(ReadinessPresentation.abbreviate("/Users/u/Documents/AutoNote", home: "/Users/u") == "~/Documents/AutoNote")
    #expect(ReadinessPresentation.abbreviate("/Users/u2/x", home: "/Users/u") == "/Users/u2/x")
    #expect(ReadinessPresentation.abbreviate("/tmp/an-e2e.1/vault", home: "/Users/u") == "/tmp/an-e2e.1/vault")
}
@Test func actionTitles()   // changeOutputFolder "保存先を変える", retryModelDownload "もう一度", installGuide "入れ方を見る", redetectClaude "もう一度探す"
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter ReadinessTests` → Expected: `cannot find 'Readiness' in scope` でビルド失敗
- [ ] **Step 3: `Readiness.swift` に上の型を実装する** — `abbreviate` は `home` の後ろに `/` が続くとき（または完全一致）だけ `~` に置き換える
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter ReadinessTests && scripts/e2e-check.sh --quick` → Expected: PASS、E2E 0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation/Readiness.swift Tests/AutoNoteCoreTests/Presentation/ReadinessTests.swift && git commit -m "feat(core): readiness model and readiness card copy"`

---

### Task 2: `FirstRunDefaults`（保存先の既定、モデルを入れるかの判定）

**Files:**
- Create: `Sources/AutoNoteCore/Storage/FirstRunDefaults.swift`
- Test: `Tests/AutoNoteCoreTests/Storage/FirstRunDefaultsTests.swift`

**Interfaces:**
- Consumes: `SettingsStore`（`load()`・`update(_:)`）、`AppPaths`
- Produces:
  - `public enum FirstRunDefaults`
  - `public enum OutputFolderOutcome: Equatable, Sendable { case unchanged, created(String), failed }`
  - `public static func defaultOutputFolder(paths: AppPaths, isDataDirectoryOverridden: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL` — 通常 `<home>/Documents/AutoNote`、override 時 `<paths.root>/vault`
  - `public static func outputFolder(forInput input: String, paths: AppPaths, isDataDirectoryOverridden: Bool, home: URL = …) -> String` — 前後の空白を除き、空なら既定パス
  - `public static func modelToDownload(installed: [String], isDataDirectoryOverridden: Bool) -> String?` — `installed` が空で override でなければ `"base"`、それ以外 nil
  - `@discardableResult public static func apply(settings: SettingsStore, paths: AppPaths, isDataDirectoryOverridden: Bool, home: URL = …, createDirectory: @Sendable (URL) throws -> Void = { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }) async -> OutputFolderOutcome`
  - パスの文字列は `url.path(percentEncoded: false)` から末尾の `/` を除いたもの（E2E 07.1 が `"${DATA}/vault"` と完全一致で比べる）

- [ ] **Step 1: 失敗するテストを書く** — `home` と `paths.root` は `TemporaryDirectory.make()`
```swift
@Test func nilBecomesDocumentsAutoNote()      // apply → .created("<home>/Documents/AutoNote")、そのフォルダが存在、settings.load().outputFolder が同じ文字列
@Test func emptyStringIsTreatedAsUnset()      // outputFolder "" で保存してから apply → 上と同じ
@Test func overrideUsesDataDirVault()         // isDataDirectoryOverridden true → .created("<root>/vault")、<home>/Documents は作られない
@Test func existingFolderIsUnchanged()        // outputFolder "/x/y" → .unchanged、createDirectory は 1 回も呼ばれない（Mutex のカウンタ）、設定はそのまま
@Test func creationFailureLeavesNil()         // createDirectory が throw → .failed、settings.load().outputFolder == nil
@Test func defaultPathOccupiedByFileLeavesNil() // <home>/Documents/AutoNote に普通のファイルを置く（既定の createDirectory のまま）→ .failed、nil のまま
@Test func existingDefaultDirectoryIsReused() // 既定フォルダが先にある → .created(そのパス)
@Test func blankInputMapsToDefault() {
    #expect(FirstRunDefaults.outputFolder(forInput: "  ", paths: paths, isDataDirectoryOverridden: false, home: home) == home.appending(path: "Documents/AutoNote").path(percentEncoded: false))
    #expect(FirstRunDefaults.outputFolder(forInput: "/a/b ", paths: paths, isDataDirectoryOverridden: false, home: home) == "/a/b")
}
@Test func modelToDownload() {
    #expect(FirstRunDefaults.modelToDownload(installed: [], isDataDirectoryOverridden: false) == "base")
    #expect(FirstRunDefaults.modelToDownload(installed: ["small"], isDataDirectoryOverridden: false) == nil)
    #expect(FirstRunDefaults.modelToDownload(installed: [], isDataDirectoryOverridden: true) == nil)
}
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter FirstRunDefaultsTests` → Expected: `cannot find 'FirstRunDefaults' in scope`
- [ ] **Step 3: `FirstRunDefaults.swift` を実装する** — `apply` は `load()` の `outputFolder` が nil か空のときだけ動き、作成が成功してから `update { $0.outputFolder = path }`（作成と保存の間に他の書き手がいても `update` の中で nil/空を見直す）。`load` が throw したら `.failed`
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter FirstRunDefaultsTests && scripts/e2e-check.sh --quick` → Expected: PASS、0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Storage/FirstRunDefaults.swift Tests/AutoNoteCoreTests/Storage/FirstRunDefaultsTests.swift && git commit -m "feat(core): first-run defaults for the output folder and the whisper model"`

---

### Task 3: `FailureExplanation`（失敗の帯の「何が — なぜ」とボタン）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/FailureExplanation.swift`
- Test: `Tests/AutoNoteCoreTests/Presentation/FailureExplanationTests.swift`

**Interfaces:**
- Consumes: `SummaryFailureKind.of(_:)`、`StageName`、`MeetingRow`・`MeetingRowState`・`QueueItemDTO`、`JobState`
- Produces:
  - `public struct FailureExplanation: Sendable, Equatable { var what: String; var why: String; var actions: [Action]; var tone: Tone }`（memberwise の public init）
  - `public enum Action: Sendable, Equatable { case installGuide, redetectClaudeAndRerun, rerun, openSystemSettings, revealAudio, delete, changeOutputFolder, loginGuide }`（設計書の 8 case。`openSystemSettings` はこの計画ではどの行も使わない）
  - `public enum Tone: Sendable, Equatable { case failure, waiting }`
  - `public enum Source: Sendable, Equatable { case job(stage: String, reason: String?, waiting: Bool = false), summary(String?) }`
  - `public static func make(_ source: Source, outputFolderPath: String) -> FailureExplanation`
  - `public static func source(row: MeetingRow, item: QueueItemDTO?) -> Source?`
  - `public static func actionTitle(_ a: Action) -> String`、`public static let transcriptAvailableNote = "文字起こしはできています。議事録は再実行で作れます"`、`public static let loginSteps = "ターミナルを開いて claude と入力し、表示に従ってログインしてください。終わったら［再実行］を押します。"`

- [ ] **Step 1: 失敗するテストを書く**

段階名: `transcribe` 文字起こし、`summarize` 議事録の作成、`write_vault`・`update_index` 保存、`automations` Automations、それ以外（`""` を含む）処理。

```swift
private let folder = "/Users/u/Documents/AutoNote"
private func make(_ s: FailureExplanation.Source) -> FailureExplanation { .make(s, outputFolderPath: folder) }
@Test func claudeNotFound() {
    let want = FailureExplanation(what: "議事録を作れませんでした", why: "Claude Code（claude）が見つかりません",
                                  actions: [.installGuide, .redetectClaudeAndRerun], tone: .failure)
    #expect(make(.summary("claude_not_found")) == want && make(.summary("claude_not_found: /opt/homebrew/bin/claude")) == want)
}
@Test func notLoggedIn()      // .summary("not_logged_in") → why "Claude Code にログインしていません"、[.loginGuide, .rerun]、.failure
@Test func noSpeech()         // .job(stage: "transcribe", reason: "no_speech") → what "音声を聞き取れませんでした"、why "録音に声が入っていないか、マイクが拾えていません"、[.revealAudio, .delete]
@Test(arguments: ["output_folder_unavailable", "output_folder_missing"]) func outputFolderWaits(reason: String)
    // .job(stage: "write_vault" と "update_index", reason:, waiting: true) → what "保存先に書けないので待っています"、why folder、[.changeOutputFolder]、.waiting
@Test func otherWaiting()     // .job(stage: "summarize", reason: "rate_limited", waiting: true) → what "議事録の作成を待っています"、why "しばらくしてから自動でやり直します"、[]、.waiting
@Test(arguments: [
    ("transcribe", "final_transcription_failed: TranscriptionError", "文字起こしに失敗しました", "文字起こしエンジンが途中で止まりました"),
    ("summarize", "final_transcript_missing", "議事録の作成に失敗しました", "文字起こしのファイルが見つかりません"),
    ("write_vault", "final_transcript_missing", "保存に失敗しました", "文字起こしのファイルが見つかりません"),
    ("automations", nil, "Automations に失敗しました", "原因がわかりません"),
    ("", "unknown_stage: x", "処理に失敗しました", "原因がわかりません"),
] as [(String, String?, String, String)]) func otherJobFailures(stage: String, reason: String?, what: String, why: String)
    // actions [.rerun]、.failure
@Test(arguments: [("rate_limited", "Claude Code の利用上限に達しました"), ("context_exceeded", "文字起こしが長すぎました"),
                  ("timed_out", "Claude Code が時間内に応答しませんでした"), ("invalid_output", "Claude Code の出力を読めませんでした"),
                  ("other", "原因がわかりません")]) func otherSummaryFailures(kind: String, why: String)
    // what "議事録を作れませんでした"、[.rerun]。.summary(nil) も why "原因がわかりません"
@Test func noInternalNamesLeak()  // 上の全 Source について what + why が /[A-Za-z]+_[A-Za-z]+/ に当たらず、"TranscriptionError" を含まない
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
@Test func actionTitles() // installGuide "入れ方を見る", redetectClaudeAndRerun "もう一度探して再実行", rerun "再実行", openSystemSettings "システム設定を開く",
                          // revealAudio "録音を聞く", delete "削除", changeOutputFolder "保存先を変える", loginGuide "ターミナルで claude を開く手順を見る"
```
`row(_:)` はテスト内のヘルパー（`MeetingRow(id: "m", state:)`）。
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter FailureExplanationTests` → Expected: `cannot find 'FailureExplanation' in scope`
- [ ] **Step 3: `FailureExplanation.swift` を実装する** — 理由は `reason` の先頭（`:` の前）で引く。知らない理由・nil はすべて「原因がわかりません」。`waiting: true` の `job` は `reason` が `output_folder_` で始まれば保存先の行、それ以外は「〈段階名〉を待っています」。`source(row:item:)` は「`item` が `waiting` かつ `notBefore != nil`」→ `job(waiting: true)`、`row.state == .failed` → `item` が `failed` ならその `stage`・`message`、無ければ `job(stage: "", reason: nil)`、`row.state == .transcriptOnly` → `summary(item?.summaryFailure)`、ほかは nil
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter FailureExplanationTests && scripts/e2e-check.sh --quick` → Expected: PASS、0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation/FailureExplanation.swift Tests/AutoNoteCoreTests/Presentation/FailureExplanationTests.swift && git commit -m "feat(core): explain job and summary failures without internal names"`

---

### Task 4: 表示規則（メニュー、保存先の語、秒の表示、短い録音、処理中の見出し、ツールバー、URL の開き先）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/FlowPresentation.swift`
- Modify: `Sources/AutoNoteCore/Presentation/MenuBarPresentation.swift`、`KeyCombo.swift`（`keyName` を public）、`NoticeContent.swift`（`.outputFolderMissing` の本文）、`LiveAdapters.swift`（`outputFolderMissing` の文言）、`MeetingListBuilder.swift`（`durationSeconds`）、`ObsidianLink.swift`（`target`）、`Sources/AutoNoteCore/IPC/WireTypes.swift`（`MeetingRow.durationSeconds`）、`AppModel.swift`（`menuBar(now:)` の引数だけ。Task 8 が本体）
- Test: `Tests/AutoNoteCoreTests/Presentation/FlowPresentationTests.swift`、既存の `MenuBarPresentationTests.swift`・`NoticeContentTests.swift`・`MeetingsAdapterTests.swift`・`MeetingListBuilderTests.swift`・`ObsidianLinkTests.swift`・`KeyComboTests.swift`・`AppModelTests.swift`（期待値の更新）

**Interfaces:**
- Consumes: `Readiness`・`ReadinessPresentation`（Task 1）、`Shortcuts`・`ShortcutBindings.combo(for:)`、`UserAction`、`RecorderState`
- Produces:
  - `MenuItem` の変更: `.startRecording(shortcut: KeyCombo?)`、`.stop(shortcut: KeyCombo?)`、`.pause(shortcut: KeyCombo?)`（`toggleRecording` / `togglePause` の値。読めなければ nil）、新 case `.readinessIssue(ReadinessRow.Item, title: String)`。ほかの case は変えない
  - `MenuBarPresentation.make(recorder:elapsedSeconds:queue:readiness:latestMinutesAvailable:rows:automationFailures:shortcuts:now:timeZone:)`（`outputFolderAvailable:` を `readiness: Readiness` に、`shortcuts: Shortcuts = Shortcuts()` を追加）。⚠ 項目は queue の行・`minutesMissing`・`automationFailed` の後、`.openWindow` の前。保存先 → Claude の順。モデルは出さない
  - 文言: 保存先 !available・path 非空 `"⚠ 保存先が見つかりません — 設定を開く…"`、path 空 `"⚠ 保存先を作れませんでした — 設定を開く…"`、claude `"⚠ 議事録の作成に Claude Code が要ります…"`
  - `AppModel.menuBar(now:)` は当面 `readiness: .assumedReady`・`shortcuts: Shortcuts()` を渡す（Task 8 が本物にする）
  - `KeyCombo.keyName: String`（public）
  - `MeetingRow.durationSeconds: Int?`（init の引数 `durationSeconds: Int? = nil` を `durationMinutes` の後に）。`MeetingListBuilder` は `manifest.duration` から `Int(d.rounded(.down))`、index だけの行は nil
  - `public enum DurationText { static func list(seconds: Int?, minutes: Int?) -> String?; static func spoken(_ seconds: Int) -> String }`
  - `public enum ShortRecordingCopy { static func band(seconds: Int?) -> String; static let transcribeTitle = "作る"; static let discardTitle = "削除" }`
  - `public enum ProcessingPresentation { static func heading(stage: String) -> String; static func engineNote(stage: String, model: Readiness.Model) -> String?; static let explainer = "文字起こし → 議事録の作成 → 保存 の順に進みます。終わると議事録がここに開きます。"; static func stoppedBand(seconds: Int) -> String; static func savedBand(path: String, home: String) -> String }`
  - `public enum MainToolbar { static func actions(for state: RecorderState) -> [UserAction] }`
  - `ObsidianLink.target(for url: URL, obsidianInstalled: Bool) -> URL`
  - 文言の変更: `NoticeContent` の `.outputFolderMissing` 本文と `LiveAdapters` の `AppCommandError.failed` を「保存先が見つかりません」。`CLIRenderer` の「出力フォルダが見つかりません」は変えない

- [ ] **Step 1: 失敗するテストを書く**

`MenuBarPresentationTests` の既存の期待値は `.startRecording(shortcut: KeyCombo(parsing: "ctrl+option+r"))` などに直し、`outputFolderAvailable: false` の箇所は `readiness`（保存先 !available）に置き換える。新規:
```swift
@Test func readinessIssuesInMenu() {
    let r = Readiness(outputFolder: .init(path: "/Volumes/Vault", available: false), model: .downloading("base", fraction: 0.4),
                      claude: .init(path: nil, found: false))
    let p = make(state: .idle, readiness: r)
    #expect(Array(p.items.suffix(6)) == [.readinessIssue(.outputFolder, title: "⚠ 保存先が見つかりません — 設定を開く…"),
                                         .readinessIssue(.claude, title: "⚠ 議事録の作成に Claude Code が要ります…"),
                                         .openWindow, .openLatestMinutes(enabled: false), .settings, .quit])
    var empty = r; empty.outputFolder.path = ""
    #expect(make(state: .idle, readiness: empty).items.contains(.readinessIssue(.outputFolder, title: "⚠ 保存先を作れませんでした — 設定を開く…")))
}
@Test func readyHasNoIssueItems()   // 完全な readiness → .readinessIssue なし、.status("出力フォルダが見つかりません") なし
@Test func shortcutsFollowSettings() {
    var s = Shortcuts(); s.toggleRecording = "ctrl+shift+k"
    #expect(make(state: .idle, shortcuts: s).items.first == .startRecording(shortcut: KeyCombo(parsing: "ctrl+shift+k")))
    let rec = make(state: .recording, shortcuts: Shortcuts())
    #expect(rec.items.contains(.stop(shortcut: KeyCombo(parsing: "ctrl+option+r"))) && rec.items.contains(.pause(shortcut: KeyCombo(parsing: "ctrl+option+p"))))
    s.toggleRecording = "zzz"
    #expect(make(state: .idle, shortcuts: s).items.first == .startRecording(shortcut: nil))
}
```
`KeyComboTests`: `KeyCombo(parsing: "ctrl+option+r")?.keyName == "r"`。`NoticeContentTests` の `.outputFolderMissing` 行と `MeetingsAdapterTests` の 2 か所を「保存先が見つかりません」に。`MeetingListBuilderTests`: `durationSecondsFromManifest`（duration 32.7 秒の manifest → 32、index だけの行 → nil）。`ObsidianLinkTests`:
```swift
@Test func webURLIsNeverSentToObsidian() {
    let web = URL(string: "https://example.com/setup")!, file = URL(filePath: "/tmp/v/会議 #1.md")
    #expect(ObsidianLink.target(for: web, obsidianInstalled: true) == web)
    #expect(ObsidianLink.target(for: file, obsidianInstalled: true) == ObsidianLink.url(for: file))
    #expect(ObsidianLink.target(for: file, obsidianInstalled: false) == file)
}
```
`FlowPresentationTests`:
```swift
@Test func durationTextForList() {
    #expect(DurationText.list(seconds: 32, minutes: 1) == "32 秒" && DurationText.list(seconds: 59, minutes: 1) == "59 秒")
    #expect(DurationText.list(seconds: 252, minutes: 4) == "4 分" && DurationText.list(seconds: nil, minutes: 4) == "4 分")
    #expect(DurationText.list(seconds: nil, minutes: nil) == nil)
}
@Test func durationTextSpoken()     // spoken(252) == "4 分 12 秒"、spoken(32) == "32 秒"、spoken(120) == "2 分"
@Test func shortRecordingBand() {
    #expect(ShortRecordingCopy.band(seconds: 32) == "32 秒の録音です。1 分未満なので自動では処理しません。文字起こしと議事録を作りますか？")
    #expect(ShortRecordingCopy.band(seconds: nil) == "1 分未満の録音です。自動では処理しません。文字起こしと議事録を作りますか？")
}
@Test(arguments: [("transcribe", "文字起こし中…"), ("summarize", "議事録を作成中…"), ("write_vault", "保存中…"),
                  ("update_index", "保存中…"), ("automations", "保存中…"), ("", "処理中…")]) func processingHeadings(stage: String, heading: String)
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
}
@Test func toolbarActionsByState() {
    #expect(MainToolbar.actions(for: .idle) == [.start] && MainToolbar.actions(for: .countdown) == [.cancelCountdown])
    #expect(MainToolbar.actions(for: .recording) == [.stop] && MainToolbar.actions(for: .grace) == [.stop])
    #expect(MainToolbar.actions(for: .paused) == [.stop, .resume])
}
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter 'MenuBarPresentationTests|FlowPresentationTests|ObsidianLinkTests|KeyComboTests|NoticeContentTests|MeetingsAdapterTests|MeetingListBuilderTests'` → Expected: ビルド失敗（`readinessIssue`・`DurationText` などが無い）
- [ ] **Step 3: 実装する** — 上の Produces のとおり。`DurationText.spoken` は 60 秒未満「N 秒」、以上「M 分 S 秒」（S が 0 なら「M 分」）。`MenuBarPresentation` のメニュー項目の保存先の判定は `!readiness.outputFolder.available`、Claude は `!readiness.claude.found`。`App` 側の `MenuBarContent` が新しい case で落ちないよう、`switch` に最小の分岐（従来どおりのボタン、⚠ 項目は `Text(title)`）だけ足してビルドを通す（見た目は Task 12）
- [ ] **Step 4: 通過を確かめる** — Run: `swift test && swift build && scripts/e2e-check.sh --quick` → Expected: 全 PASS、ビルド成功、0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore Sources/AutoNoteApp/MenuBarContent.swift Tests/AutoNoteCoreTests && git commit -m "feat(core): flow copy, readiness menu items, shortcut hints and 保存先 wording"`

---

### Task 5: `TranscribeStage` がジョブごとにエンジンを決め、無ければライブで代用する

**Files:**
- Modify: `Sources/AutoNoteCore/Minutes/Stages/TranscribeStage.swift`、`Sources/AutoNoteCore/Minutes/PostProcessingPipeline.swift`、`Sources/AutoNoteCore/Model/Utterance.swift`
- Test: `Tests/AutoNoteCoreTests/Minutes/TranscribeStageTests.swift`、`Tests/AutoNoteCoreTests/Minutes/PipelineEndToEndTests.swift`

**Interfaces:**
- Consumes: `FinalTranscriptionRunner`、`LiveFeed.isMarker(_:)`、`StageError.failed(reason:)`
- Produces:
  - `TranscribeStage.init(resolveRunner: @escaping @Sendable (Language) async -> FinalTranscriptionRunner?, services: SharedVaultServices = .standard)`。既存の `init(runner:services:)` は `resolveRunner: { _ in runner }` に委ねる
  - `PostProcessingPipeline.standardStages(resolveRunner:summarizer:timeZone:services:)`（既存の `standardStages(runner:…)` はこれに委ねる）
  - `Transcript.liveSubstituteEngineLabel = "Apple 音声入力（リアルタイム版）"`（エンジンが 1 つも無いとき、ライブは Apple の音声入力しかありえない。whisper のライブもモデルが要る）
  - 失敗理由 `"no_speech"`（Task 3 の表が読む）

- [ ] **Step 1: 失敗するテストを書く**（既存の `Fixture`・`writeLive`・`context`・`job` を使う）
```swift
@Test func noEngineUsesLiveAsFinal() async throws {
    // resolveRunner { _ in nil }、live に発話 2 件 → run が throw しない
    // job.transcriptEngine == Transcript.liveSubstituteEngineLabel、final.json と raw.json の engine も同じ、final の発話 2 件
    // manifest.status == .transcribed、job.lastError == nil
}
@Test func noEngineAndEmptyLiveIsNoSpeech()   // live [] → #expect(throws: StageError.failed(reason: "no_speech"))、manifest.status == .failed
@Test func noEngineAndNoLiveFileIsNoSpeech()  // live.json なし → 同上
@Test func markersOnlyIsNoSpeech()            // live がブックマークと一時停止の印だけ（各要素で LiveFeed.isMarker == true をテスト内でも確かめる）→ no_speech
@Test func resolvesOnEveryRun() async throws {
    // 1 回目は nil（ライブ代用）、2 回目は FakeBatchTranscriber の runner を返す closure。呼ばれた回数 2、受け取った言語 [.ja, .ja]（manifest.language）
    // 2 回目の job.transcriptEngine == "whisper.cpp large-v3-turbo"
}
```
既存の `fallsBackToLiveTranscript`（runner が失敗 → `fallbackEngineLabel`）・`failsWithoutLiveTranscript`・`emptyLiveTranscriptIsNotUsed`（どちらも `final_transcription_failed:`）は変えずに通ること。`PipelineEndToEndTests` に `standardStagesAcceptResolver`（`standardStages(resolveRunner: { _ in nil })` の名前が `[transcribe, summarize, write_vault, update_index]`）。
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter 'TranscribeStageTests|PipelineEndToEndTests'` → Expected: `extra argument 'resolveRunner'` でビルド失敗
- [ ] **Step 3: 実装する** — `run` の先頭で `await resolveRunner(manifest.language)`。nil なら `readLive` の発話から `LiveFeed.isMarker` を除いたものが空なら manifest を `.failed` にして `no_speech`、あれば既存の `writeFallback`（置換 → フィラー除去の順はそのまま）を `liveSubstituteEngineLabel` で呼ぶ。失敗の記録（`logger.error`）は出さず `notice` で「エンジンなし、ライブを確定版に」と残す。runner がある経路は今のまま
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter 'TranscribeStageTests|PipelineEndToEndTests|AppWiringTests' && swift build && scripts/e2e-check.sh --quick` → Expected: PASS、0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Minutes Sources/AutoNoteCore/Model/Utterance.swift Tests/AutoNoteCoreTests/Minutes && git commit -m "feat(core): resolve the batch engine per job and use the live transcript when none is installed"`

---

### Task 6: 入力レベル（直近 1 秒のピーク、`RecorderPort.levels()`、メーターと「音を拾えていません」の判定）

**Files:**
- Create: `Sources/AutoNoteCore/Audio/RecentPeakWindow.swift`、`Sources/AutoNoteCore/Presentation/InputLevel.swift`
- Modify: `Sources/AutoNoteCore/Audio/RecordingSession.swift`（`levels()`、開始時のリセット）、`Sources/AutoNoteCore/Audio/RecordingSession+Pipeline.swift`（`handle` で更新）、`Sources/AutoNoteCore/Presentation/Ports.swift`（`RecorderPort.levels()`）、`Sources/AutoNoteCore/Presentation/LiveAdapters.swift`（`CoordinatorRecorderPort`）、`Sources/AutoNoteTestSupport/FakePorts.swift`（`FakeRecorderPort`）
- Test: `Tests/AutoNoteCoreTests/Audio/RecentPeakWindowTests.swift`、`Tests/AutoNoteCoreTests/Audio/RecordingSessionTests.swift`、`Tests/AutoNoteCoreTests/Presentation/InputLevelTests.swift`

**Interfaces:**
- Consumes: `AudioLevel.peakDBFS(_:)`、`AudioChunk.start`、`MeetingClock.now()`、`SessionHarness`（テスト）
- Produces:
  - `public struct TrackLevel: Sendable, Equatable { public var track: Track; public var peakDBFS: Double; public init(track:peakDBFS:) }`
  - `struct RecentPeakWindow: Sendable { static let window = 1.0; mutating func observe(peakDBFS: Double, at: TimelineTime); func peak(at now: TimelineTime) -> Double /* (now - 1 秒, now] のチャンクの最大。無ければ -infinity */ }`（internal）
  - `RecordingSession.levels() -> [TrackLevel]`（録音中・一時停止中は `[mic, system]` の順に `clock.now()` での値。idle は `[]`。一時停止中のチャンクは今どおり捨てるので値は -infinity に落ちる）
  - `RecorderPort.levels() async -> [TrackLevel]`、`CoordinatorRecorderPort.init(coordinator:elapsed:levels: @escaping @Sendable () async -> [TrackLevel] = { [] })`、`FakeRecorderPort.setLevels(_:)`（既定 `[]`）
  - `public struct InputLevel: Sendable, Equatable { public var bars: Int /* 0...5 */; public var quiet: Bool }`
  - `public struct InputLevelTracker: Sendable { public static let quietThresholdDBFS = -60.0; public static let quietTicks = 10; public init(); public mutating func observe(_ levels: [TrackLevel], recording: Bool) -> InputLevel; public static func bars(peakDBFS: Double) -> Int }`

- [ ] **Step 1: 失敗するテストを書く**
```swift
// RecentPeakWindowTests
@Test func keepsTheLastSecond() {
    var w = RecentPeakWindow()
    w.observe(peakDBFS: -20, at: TimelineTime(seconds: 0.2))
    #expect(w.peak(at: TimelineTime(seconds: 0.5)) == -20)
    w.observe(peakDBFS: -50, at: TimelineTime(seconds: 1.5))
    #expect(w.peak(at: TimelineTime(seconds: 1.6)) == -50)          // 0.2 は窓の外
    #expect(w.peak(at: TimelineTime(seconds: 3.0)) == -.infinity)
}
@Test func maxWithinWindow()   // 0.1 に -30、0.4 に -10 → peak(at 0.5) == -10
// RecordingSessionTests（SessionHarness）
@Test func levelsReportRecentPeakPerTrack() async throws {
    // start → h.mic.emit(16384 の定数 1600 サンプル、start = 現在の clock)、h.system.emit(0 だけ) → await h.session.waitUntilIdle()
    // levels: mic の peakDBFS が -6.02 ± 0.1、system は -infinity。stop 後は []
}
// InputLevelTests
@Test(arguments: [(-70.0, 0), (-60.0, 1), (-48.0, 2), (-36.0, 3), (-24.0, 4), (-12.0, 5), (0.0, 5), (-Double.infinity, 0)]) func bars(db: Double, bars: Int)
@Test func louderTrackWins()          // [mic -70, system -20] → bars 4
@Test func quietAfterTenSilentTicks() // [mic -70] を 9 回 → quiet false、10 回目 → true、次に -30 → false
@Test func pausedTicksDoNotCount()    // recording: false の observe は数えず、quiet を false にする
```
`bars` の閾値は −60・−48・−36・−24・−12（それ以上の段の数）。
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter 'RecentPeakWindowTests|RecordingSessionTests|InputLevelTests'` → Expected: ビルド失敗
- [ ] **Step 3: 実装する** — `RecentPeakWindow` は (時刻, ピーク) の小さな配列で、`observe` のたびに 1 秒より古いものを捨てる。`RecordingSession.handle` で `stats` を更新する所の隣で `recentPeaks[track].observe(peakDBFS: AudioLevel.peakDBFS(chunk.samples), at: chunk.start)`。`start` で両トラックを作り直す
- [ ] **Step 4: 通過を確かめる** — Run: `swift test && scripts/e2e-check.sh --quick` → Expected: 全 PASS、0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore Sources/AutoNoteTestSupport Tests/AutoNoteCoreTests && git commit -m "feat(core): recent input level per track and the quiet-input rule"`

---

### Task 7: `ReadinessPort` と `LiveReadinessPort`（保存先・モデル・claude を読む、初回のダウンロード）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/ReadinessPort.swift`
- Modify: `Sources/AutoNoteCore/Presentation/Ports.swift`（`AppPorts.readiness`）、`Sources/AutoNoteTestSupport/FakePorts.swift`（`FakeReadinessPort`、`FakePorts.readiness`）、`Sources/AutoNoteApp/AppEnvironment.swift`（`AppPorts(…)` に渡すだけ。組み立ての本体は Task 9）
- Test: `Tests/AutoNoteCoreTests/Presentation/ReadinessPortTests.swift`

**Interfaces:**
- Consumes: `Readiness`（Task 1）、`FirstRunDefaults.modelToDownload`（Task 2）、`SettingsStore`、`OutputFolderPort`、`ModelManager`（`installed()`・`download(_:progress:)`）、`EngineCatalog.resolve(role:language:override:)`、`EngineChoice.fromSettings`、`ClaudeLocator.locate()`、`FileOpener`、TestSupport `FakeModelDownloader`・`FakeOutputFolderPort`・`FakeFileOpener`
- Produces:
  - `public protocol ReadinessPort: Sendable { func current() async -> Readiness; func updates() async -> AsyncStream<Readiness.Model> /* 呼ぶたびに新しい購読。最初に今の値 */; func redetectClaude() async -> Readiness.Claude; func retryModelDownload() async; func installGuide() async }`
  - `public actor LiveReadinessPort: ReadinessPort` — `public init(settings: SettingsStore, outputFolder: any OutputFolderPort, models: ModelManager, catalog: EngineCatalog, opener: any FileOpener, locate: @escaping @Sendable () async -> String? = { await ClaudeLocator.locate() }, isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })`、`public func startFirstRunDownload(isDataDirectoryOverridden: Bool) async -> String? /* 始めたモデル名 */`、`public static let firstRunModel = "base"`、`public static let installGuideURL: URL`（Claude Code の公式インストール手順。実装時に現行の URL を確かめる）、`public static func failureReason(_ error: any Error) -> String`
  - `AppPorts.init(…, opener:, readiness: any ReadinessPort)`、`AppPorts.readiness`
  - `FakeReadinessPort`（actor）: `init(_ r: Readiness = .assumedReady)`、`calls: [String]`（`"redetectClaude"`・`"retryModelDownload"`・`"installGuide"`）、`setCurrent(_:)`、`send(_ model:)`、`setRedetectResult(_ claude:)`

- [ ] **Step 1: 失敗するテストを書く** — `ModelManager(directory:catalog:downloader:)` の catalog は `WhisperModel(name: "base", url:, sizeBytes: payload.count, sha256: payload の SHA-256)` の 1 件（計画 04 の `ModelManager` のテストと同じ作り方）
```swift
@Test func currentReadsSettingsFolderAndClaude()  // outputFolder = 一時フォルダ、claudePath "/fake/claude"、isExecutable { $0 == "/fake/claude" }、FakeOutputFolderPort(available: true)
    // → current() == Readiness(outputFolder: .init(path: <folder>, available: true), model: .none, claude: .init(path: "/fake/claude", found: true))
@Test func unsetFolderIsUnavailableWithEmptyPath() // outputFolder nil → .init(path: "", available: false)。claudePath nil → .init(path: nil, found: false)
@Test func firstRunDownloadStreamsProgress()  // startFirstRunDownload(false) == "base"。updates() が .none → .downloading("base", fraction: 0.5) → .installed("base") を流し、current().model == .installed("base")
@Test func progressIsYieldedPerWholePercent() // テスト内の downloader が 10_000 回 progress を呼ぶ → .downloading の受信は 101 回以下、fraction は単調増加
@Test func overrideNeverDownloads()           // startFirstRunDownload(true) == nil、downloader.callCount == 0、current().model == .none
@Test func alreadyInstalledDoesNotDownload()  // 先に download 済み → startFirstRunDownload(false) == nil、callCount は 1 のまま
@Test func failedDownloadIsReportedAndRetried() // downloader が URLError(.notConnectedToInternet) → .failed("base", reason: "ネットワークにつながりませんでした")。retryModelDownload で callCount 2
@Test func failureReasons() {
    #expect(LiveReadinessPort.failureReason(URLError(.timedOut)) == "ネットワークにつながりませんでした")
    #expect(LiveReadinessPort.failureReason(ModelError.checksumMismatch) == "ダウンロードしたファイルが壊れていました")
    #expect(LiveReadinessPort.failureReason(ModelError.sizeMismatch(expected: 1, actual: 2)) == "ダウンロードしたファイルが壊れていました")
    #expect(LiveReadinessPort.failureReason(FakeError()) == "ダウンロードが途中で止まりました")
}
@Test func redetectClaudeSavesFoundPath()     // locate → "/fake/claude" → 戻り値 found、settings.load().claudePath == "/fake/claude"
@Test func redetectClaudeNotFoundKeepsSetting() // locate → nil、既存の claudePath はそのまま、found は isExecutable(既存) の結果
@Test func installGuideOpensTheWebPage()      // FakeFileOpener.opened == [LiveReadinessPort.installGuideURL]、scheme == "https"
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter ReadinessPortTests` → Expected: `cannot find 'LiveReadinessPort' in scope`
- [ ] **Step 3: 実装する** — `current().model`: ダウンロード中なら `.downloading(name, 最後の fraction)`、直前の失敗があれば `.failed`、なければ `catalog.resolve(role: .batch, language: s.defaultLanguage, override: EngineChoice.fromSettings(kind: s.finalEngine, model: s.finalModel, role: .batch, machine: catalog.machine))` が whisper なら `.installed(model)`、それ以外 `.none`。ダウンロードは actor の外の `Task` で走らせ（`ModelManager` が二重起動を畳む）、進捗は `Int(fraction * 100)` が変わったときだけ購読者へ。`outputFolder.available` は path が空でなく `outputFolder.isAvailable()`。`FakePorts`・`AppEnvironment` の `AppPorts(…)` に `readiness:` を渡す（`AppEnvironment` は Task 9 まで `LiveReadinessPort` をその場で作って渡すだけ）
- [ ] **Step 4: 通過を確かめる** — Run: `swift test && swift build && scripts/e2e-check.sh --quick` → Expected: 全 PASS、0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore Sources/AutoNoteTestSupport Sources/AutoNoteApp/AppEnvironment.swift Tests/AutoNoteCoreTests && git commit -m "feat(core): readiness port with first-run model download and claude re-detection"`

---

### Task 8: `AppModel`（準備・入力レベル・この起動中の録音・停止の帯・自動で選ぶ・短い録音の帯）

**Files:**
- Modify: `Sources/AutoNoteCore/Presentation/AppModel.swift`
- Test: `Tests/AutoNoteCoreTests/Presentation/AppModelTests.swift`

**Interfaces:**
- Consumes: `ReadinessPort`（Task 7）、`RecorderPort.levels()`・`InputLevelTracker`（Task 6）、`MenuBarPresentation.make(…readiness:…shortcuts:…)`（Task 4）、`RecordingEvent.started(MeetingID)`・`.stopped(Manifest, StopReason)`、`Manifest.duration`
- Produces（すべて `AppModel` のメンバー）:
  - `public private(set) var readiness: Readiness = .assumedReady`（`run()` で `current()`、`refresh()` で保存先と claude だけ読み直す、`updates()` でモデル。購読は 6 本になるので `streamCount = 6`）
  - `public var shortcuts = Shortcuts()`（App が起動時と設定保存時に入れる。`menuBar(now:)` が使う）
  - `public private(set) var inputLevel: InputLevel?`（1 秒 tick の `updateElapsed` で `levels()` を読む。録音中・一時停止中・猶予中で `meetingID != nil` のときだけ、ほかは nil。`.started` でトラッカーを作り直す）
  - `public private(set) var recordedThisSession: Set<MeetingID>`（`.started(id)` で追加。`minutesReady` が呼ばれたら結果にかかわらず外す。`meetings` の更新でその行が `.failed` か `.transcriptOnly` になったら外す。こうして再生成・再実行・取り込みでは選択を変えない）
  - `public struct StoppedBand: Equatable, Sendable { public var id: MeetingID; public var seconds: Int }`、`public private(set) var stoppedBand: StoppedBand?`（`.stopped(m, _)` で `Int(m.duration ?? 0)`、`bandDuration` 後に nil）
  - `public struct JustSaved: Equatable, Sendable { public var id: MeetingID; public var path: String }`、`public private(set) var justSaved: JustSaved?`（`selectedMeetingID` が別の id に変わったら nil）
  - `@discardableResult public func minutesReady(_ id: MeetingID, path: String?, windowOpen: Bool) -> Bool`
  - `UserAction` に `.redetectClaude`、`.redetectClaudeAndRerun(MeetingID)`、`.retryModelDownload`、`.installGuide` を追加
  - `AppModel.init(ports:now:timeZone:bandDuration: Duration = .seconds(5))`
  - `.recordingTooShort` の帯は `meetings` の `.tooShort` 行から作る（行が消えたら帯を消して `withdrawNotice`）。上書き確認の `syncOverwritePrompts` と同じ流れ

- [ ] **Step 1: 失敗するテストを書く**（`start(_:)`・`recording(_:)` の既存ヘルパーを使う）
```swift
@Test func readinessLoadsAndFollowsModelStream()   // FakeReadinessPort の current: model .none → readiness.model == .none。send(.downloading("base", fraction: 0.5)) → 同じ値に
@Test func refreshRereadsFolderAndClaudeButKeepsModel() // setCurrent で claude.found false・model .none、先に send(.downloading…) → refresh 後 claude.found false、model は .downloading のまま
@Test func menuBarUsesReadinessAndShortcuts()      // claude なし → menuBar の items に .readinessIssue(.claude, …)。shortcuts.toggleRecording = "ctrl+shift+k" → 先頭 .startRecording(shortcut: KeyCombo(parsing: "ctrl+shift+k"))
@Test func inputLevelTicksWhileRecording() {
    // setLevels([mic -20, system -70]) → recording() を send → inputLevel == InputLevel(bars: 4, quiet: false)。idle を send → nil
}
@Test func startedAddsToRecordedThisSession()      // .started(m1) → recordedThisSession == [m1]
@Test func stoppedSelectsMeetingAndShowsBand() {
    // bandDuration .milliseconds(50)。selectedMeetingID nil で .stopped(duration 252 秒の manifest m1, .manual)
    // → selectedMeetingID == m1、stoppedBand == StoppedBand(id: m1, seconds: 252)。200 ms 後 nil
}
@Test func stoppedKeepsExistingSelection()         // 先に別の会議を選んでいれば選択は変わらない（帯は出る）
@Test func minutesReadySelectsRecordedMeetingWhenWindowOpen() // .started(m1) のあと minutesReady(m1, path: "/v/a.md", windowOpen: true) == true、selectedMeetingID == m1、justSaved == JustSaved(id: m1, path: "/v/a.md")
@Test func minutesReadyIgnoresImportsAndClosedWindow() // .started の無い m2 → false。m1 でも windowOpen false → false。どちらも選択・justSaved は変わらない
@Test func minutesReadyDoesNotStealEditorSelection() {
    // .started(m1)、選択中の m2 の行が .minutesGenerated → false、選択は m2 のまま
    // m2 の行が .processing なら → true、m1 に移る
}
@Test func minutesReadyOnlyOncePerRecording()     // 1 回目 true のあと同じ id で 2 回目 → false（再生成で選択を変えない）
@Test func failedOrTranscriptOnlyEndsAutoOpen()   // .started(m1) → rows の m1 が .transcriptOnly → recordedThisSession に m1 が無い → 後の minutesReady(m1…) == false
@Test func justSavedClearsOnReselect()             // justSaved のあと selectedMeetingID = m2 → nil。m1 を選び直しても戻らない
@Test func tooShortPromptsFollowRows() {
    // rows に .tooShort の m1 → prompts == [.recordingTooShort(m1)]（noticePosted を呼ばなくても）
    // rows の m1 が .processing に → prompts から消え、withdrawNotice が "meeting.tooShort.<m1>" で呼ばれる
}
@Test func readinessActions() {
    // perform(.redetectClaude) → fake.calls に "redetectClaude"、readiness.claude が setRedetectResult の値
    // setRedetectResult(found) で perform(.redetectClaudeAndRerun(m1)) → queue.calls == ["retry(m1)"]
    // found false → lastError == "Claude Code（claude）が見つかりません"、retry は呼ばれない
    // perform(.retryModelDownload) / perform(.installGuide) → それぞれ calls に記録
}
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AppModelTests` → Expected: ビルド失敗（`readiness`・`minutesReady` が無い）
- [ ] **Step 3: 実装する** — `minutesReady` の条件: `recordedThisSession.contains(id) && windowOpen` かつ「何も選ばれていない、`id` 自身が選ばれている、または選ばれている行が `.minutesGenerated` でない」。満たせば `selectedMeetingID = id`、`path` があれば `justSaved`。`stoppedBand` の消去は `Task.sleep(for: bandDuration)` のあと、同じ id のときだけ nil。`.redetectClaudeAndRerun` の not found は `AppCommandError.notFound("Claude Code（claude）が見つかりません")` を投げて `perform` の `lastError` に任せる
- [ ] **Step 4: 通過を確かめる** — Run: `swift test && swift build && scripts/e2e-check.sh --quick` → Expected: 全 PASS、0 failed
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation/AppModel.swift Tests/AutoNoteCoreTests/Presentation/AppModelTests.swift && git commit -m "feat(core): app model tracks readiness, input level, this session's recordings and auto-selection"`

---

### Task 9: 起動順と配線（既定値、初回ダウンロード、同意のあと窓を開く、ジョブごとのエンジン、自動で選ぶ）と E2E 07.1・07.2・07.4

**Files:**
- Modify: `Sources/AutoNoteApp/AppDelegate.swift`、`Sources/AutoNoteApp/AppEnvironment.swift`、`Sources/AutoNoteApp/AppShell.swift`、`Sources/AutoNoteApp/WorkspaceOpener.swift`、`Sources/AutoNoteApp/Settings/SettingsView.swift`（`SettingsTab` の定義だけ）、`Sources/AutoNoteApp/MainWindow/MainWindow.swift`（`onAppear` / `onDisappear` だけ）、`scripts/e2e-check.sh`
- Create: `Tests/Fixtures/queue/20261025-0930-c3d4.json`、`Tests/AutoNoteCoreTests/Minutes/E2EFixtureTests.swift`

**Interfaces:**
- Consumes: `FirstRunDefaults.apply`（Task 2）、`LiveReadinessPort`（Task 7）、`TranscribeStage`・`standardStages(resolveRunner:)`（Task 5）、`AppModel.minutesReady`・`shortcuts`（Task 8）、`ObsidianLink.target`（Task 4）、`CoordinatorRecorderPort(…levels:)`・`RecordingSession.levels()`（Task 6）
- Produces:
  - `AppEnvironment.readiness: LiveReadinessPort`、`AppEnvironment.isMainWindowOpen: @MainActor () -> Bool`（既定 `{ false }`。AppDelegate が `shell` を見るよう差し替える）
  - `AppShell.isMainWindowOpen: Bool`（`@ObservationIgnored`。`MainWindow` の `onAppear` で true、`onDisappear` で false）
  - `AppShell.settingsTab: SettingsTab`（Task 12 が `SettingsView` に束ねる。ここでは `enum SettingsTab: Hashable { case general, devices, transcription, dictionary, minutes, automations, retention, shortcuts }` を `SettingsView.swift` に置き、既定 `.general`）と `func showSettings(_ tab: SettingsTab, using openSettings: OpenSettingsAction)`（tab を入れ、`NSApp.activate(ignoringOtherApps: true)`、`openSettings()`。保存はしない）
  - ログ行（stderr、E2E が読む）: `AutoNote: first run: output folder <path>`（`.created` のとき）、`AutoNote: first run: model download skipped (data directory overridden)`、`AutoNote: first run: model download started <name>`

- [ ] **Step 1: E2E 項目とフィクスチャのテストを書く**
  - `Tests/Fixtures/queue/20261025-0930-c3d4.json`: `Job(id: "20261025-0930-c3d4", meeting: "20261025-0930-c3d4", stages: StageName.all, completedStages: [], state: .failed, attempts: 1, lastError: "final_transcription_failed: TranscriptionError", notBefore: nil, createdAt: 2026-10-25T00:33:00Z)` を `AutoNoteJSON.encoder()` で書いたもの（一度だけ生成してコミット）
  - `E2EFixtureTests.failedJobFixtureDecodes`: そのファイルを `AutoNoteJSON.decoder()` で `Job` に読み、`state == .failed && lastError == "final_transcription_failed: TranscriptionError"`
  - `check_app_launch` の起動前に、上のファイルを `${DATA}/queue/jobs/` へ、`Tests/Fixtures/meetings/20261025-0930-c3d4/manifest.json` を `${DATA}/recordings/20261025-0930-c3d4/` へ写す（`settings.json` は今のまま `output_folder` なし）
  - `check_first_run_output_folder`（`CURRENT="07.1 起動後に <DATA>/vault ができ settings.json に書かれる"`）: `app_or_skip`。最大 5 秒、`[[ -d "${DATA}/vault" ]]` と `plutil -extract output_folder raw -o - "${DATA}/settings.json"` == `"${DATA}/vault"` を待つ。満たせば PASS、時間切れは FAIL（`LAST_LOG="${WORK}/app.log"`）
  - `check_first_run_no_download`（`"07.2 AUTONOTE_DATA_DIR 下ではモデルをダウンロードしない"`）: 3 秒待ってから `${DATA}/models/ggml-*`（`.partial` を含む）が 0 件で、`app.log` に `model download skipped (data directory overridden)` があれば PASS
  - `check_failure_message_compat`（`"07.4 status --json の失敗 message は従来の形式"`）: `app_or_skip`・`cli_or_skip`。`status --json` の `status.queue` から `meeting_id == 20261025-0930-c3d4` の要素の `message` が `final_transcription_failed: TranscriptionError` のまま（`plutil` で `status.queue.0.message`。要素は 1 件だけ）
  - CHECKS: `check_app_launch` の直後に 07.1・07.2、`check_status_over_socket` の直後に 07.4
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter E2EFixtureTests && scripts/build-app.sh && scripts/e2e-check.sh` → Expected: フィクスチャのテストは PASS、07.1・07.2 が FAIL（まだ既定値を書かない）、07.4 は PASS（従来の形式の確認なので最初から通る。以後の回帰を見張る）、ほかは今までどおり
- [ ] **Step 3: 実装する**
  - `AppDelegate.launch`: 二重起動の確認の後、`AppEnvironment.make` の前に `let paths = AppPaths.resolve(environment:)`、`try? paths.createBaseDirectories()`、`FirstRunDefaults.apply(settings: SettingsStore(paths: paths), paths: paths, isDataDirectoryOverridden: AppIdentity.isDataDirectoryOverridden(environment))`。結果をログ行で出す。失敗しても起動は続ける
  - `make` の後: `model.shortcuts = s.shortcuts`、`env.isMainWindowOpen = { shell.isMainWindowOpen }`、`Task { if let name = await env.readiness.startFirstRunDownload(isDataDirectoryOverridden: env.isDataDirectoryOverridden) { NSLog(started) } else if env.isDataDirectoryOverridden { NSLog(skipped) } }`（起動の経路を待たせない）。`ClaudeLocator.fillDefaultPath` の detached Task は終わったら `await model.refresh()`
  - `shell.consentAccepted`: `consentNoticeShown` を保存したあと `shell.open(AppShell.mainWindowID)`、それからマイク許可（今の順序）
  - `AppEnvironment.make`: `LiveReadinessPort(settings:outputFolder: PortableOutputFolderPort(output:), models:, catalog:, opener: WorkspaceOpener())` を作り `AppPorts.readiness` と `env.readiness` に。`CoordinatorRecorderPort(…, levels: { await session.levels() })`。`StageBuilder.standard(for:)` は `PostProcessingPipeline.standardStages(resolveRunner:)` を返し、closure は `catalog.resolve(role: .batch, language: $0, override: <s の finalEngine/finalModel>)` が nil なら nil、あれば `FinalTranscriptionRunner(transcriber: LazyBatchTranscriber(…), engineName: choice.displayName, paths:, gate:)`（`EngineCatalog.defaults(for:).batch` への固定は消す。runner はジョブごとに作ってよい）
  - `settingsSaved`: `model.shortcuts = new.shortcuts` を足す
  - `relayQueueNotices`: `.minutesGenerated(id, _)` を送った直後（重複排除を通ったときだけ）に `model.minutesReady(id, path: model.meetings.first { $0.id == id.rawValue }?.filePath, windowOpen: isMainWindowOpen())`。ウィンドウを開かない・前面にしない
  - `WorkspaceOpener.open`: `workspace.open(ObsidianLink.target(for: file, obsidianInstalled: <X38 の判定>))`
- [ ] **Step 4: 通過を確かめる** — Run: `swift test && scripts/build-app.sh && scripts/e2e-check.sh` → Expected: 0 failed（07.1・07.2・07.4 を含む。06.3〜06.7 も PASS）
- [ ] **Step 5: 同意のあと窓が開くことを確かめる** — 新しい `AUTONOTE_DATA_DIR=$(mktemp -d /tmp/an-07.XXXXXX)` に `{"launch_at_login": false}` だけの `settings.json` を置いて `build/AutoNote.app/Contents/MacOS/AutoNoteApp` を起動し、osascript で「OK」ボタン（同意ウィンドウ）を押す → 2 秒以内に `name of every window of process "AutoNoteApp"` に「AutoNote」のメインウィンドウ（同意ウィンドウと別の、ツールバーを持つ方）が現れる。`settings.json` に `"consent_notice_shown": true` と `"output_folder": "<DATA>/vault"`。アクセシビリティ権限が無ければ 👤（初回の許可だけ利用者に頼む）
- [ ] **Step 6: コミット** — `git add Sources/AutoNoteApp scripts/e2e-check.sh Tests/Fixtures/queue Tests/AutoNoteCoreTests/Minutes/E2EFixtureTests.swift && git commit -m "feat(app): first-run defaults at launch, per-job batch engine, open the window after consent (E2E 07.1, 07.2, 07.4)"`

---

### Task 10: メインウィンドウ（ツールバーの主ボタン、空状態と準備カード、準備の帯、録音中のメーター、停止の帯）

**Files:**
- Create: `Sources/AutoNoteApp/MainWindow/EmptyStateView.swift`（空状態と準備カード）、`Sources/AutoNoteApp/MainWindow/ReadinessActions.swift`（`ReadinessRow.Action` → 動作）、`Sources/AutoNoteApp/MainWindow/LevelMeter.swift`
- Modify: `Sources/AutoNoteApp/MainWindow/MainWindow.swift`、`StatusHeader.swift`、`RecordingDetailView.swift`（「聞き取り中…」）

**Interfaces:**
- Consumes: `MainToolbar.actions(for:)`・`ProcessingPresentation.stoppedBand`（Task 4）、`ReadinessPresentation.rows` / `bands` / `actionTitle`（Task 1）、`AppModel.readiness`・`inputLevel`・`stoppedBand`・`UserAction.redetectClaude` / `.retryModelDownload` / `.installGuide`（Task 8）、`AppShell.showSettings(_:using:)`（Task 9）
- Produces: `struct ReadinessActionButton: View`（`ReadinessRow.Action` を 1 つ受けて、`.changeOutputFolder` → `shell.showSettings(.general, using: openSettings)`、ほかは `model.perform(.retryModelDownload / .installGuide / .redetectClaude)`）。Task 11・12 は帯のボタンにこれを使う

- [ ] **Step 1: 画面を書く**
  - ツールバー: 取り込みアイコンの**左**に `MainToolbar.actions(for: model.recorder.state)` を並べる。`.start` は `Label("録音を開始", systemImage: "record.circle")` で `.buttonStyle(.borderedProminent)`、`.stop` は「停止」（`stop.fill`、確認なし）、`.resume` は「再開」（`play.fill`）、`.cancelCountdown` は「取り消す」。`keyboardShortcut` は付けない。押すと `model.perform(action)`
  - 空状態（`model.meetings.isEmpty`、何も選ばれていない、録音中でない）: 上から `waveform` のアイコン、「録音はメニューバーの 〰️ か、上の「録音を開始」から」、その下に小さく「音声ファイルをここへドラッグすると取り込めます」、「止めると文字起こしと議事録が自動でできます。」、下部に準備カード（`ReadinessPresentation.rows` の 3 行。左に title、右に status と ✓／ボタン）。会議が 1 件以上なら空状態は出さず、従来の「会議を選んでください」
  - 準備の帯: 会議が 1 件以上のとき、`StatusHeader` が `ReadinessPresentation.bands` の各行を既存の `Band` で 1 行ずつ（band の文言、右に `ReadinessActionButton`）。旧「出力フォルダが未設定です／見つかりません」の帯と `outputFolderConfigured` の読み込みは消す
  - 録音帯: `● 録音中 0:18  ▁▃▅▂▄  <マイク名>`。メーターは `LevelMeter(bars: model.inputLevel?.bars ?? 0)`（5 本、1 Hz で `inputLevel` が変わるだけ）。`inputLevel?.quiet == true` ならメーターの右に「音を拾えていません」（`.orange`）。マイク名は録音開始時に `AVCaptureDevice.default(for: .audio)?.localizedName` を 1 回読む（nil なら出さない）
  - 停止の帯: `model.stoppedBand` があれば緑の `Band(systemImage: "checkmark.circle.fill", tint: .green)` に `ProcessingPresentation.stoppedBand(seconds:)`
  - `RecordingDetailView`: `model.live.lines` が空なら中央に「聞き取り中…」
  - `MainWindow`（`MainWindowContent`）の `onAppear` / `onDisappear` は Task 9 のとおり
- [ ] **Step 2: ビルドを確かめる** — Run: `swift build && scripts/build-app.sh` → Expected: 成功
- [ ] **Step 3: 起動して確かめる（osascript）** — 新しい `AUTONOTE_DATA_DIR`（`consent_notice_shown: true`、`launch_at_login: false`、`claude_path: "/nonexistent/claude"`）で起動し、メニューの「ウィンドウを開く」を押す。`entire contents of window "AutoNote"` の静的テキストに「録音はメニューバーの 〰️ か、上の「録音を開始」から」「保存先」「`<DATA>/vault`」（override 下なので `~` の省略は無い）「文字起こしモデルがありません（Apple 音声入力で文字起こしします）」「見つかりません」があり、ボタン「録音を開始」「入れ方を見る」「もう一度探す」がある。`autonote start` の 3 秒後、ボタンが「停止」に変わり、静的テキストに「録音中」。`autonote stop` の後に「録音を保存しました（」で始まる帯が出て、5 秒後に消える
- [ ] **Step 4: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed（06.7 の CPU も 60 % 未満のまま）。`git add Sources/AutoNoteApp/MainWindow && git commit -m "feat(app): main window toolbar record button, empty state with readiness card, input meter"`

---

### Task 11: 処理中・短い録音・失敗・完了の画面

**Files:**
- Create: `Sources/AutoNoteApp/MainWindow/FailureBand.swift`（`FailureExplanation` の帯とボタンの動作）
- Modify: `Sources/AutoNoteApp/MainWindow/ProcessingDetailView.swift`、`TooShortView.swift`、`CompletedDetailView.swift`（`MinutesMissingView` を含む）、`StatusHeader.swift`（短い録音の帯）、`MeetingListView.swift`（長さの表示）

**Interfaces:**
- Consumes: `ProcessingPresentation`・`ShortRecordingCopy`・`DurationText`（Task 4）、`FailureExplanation.source(row:item:)` / `make(_:outputFolderPath:)` / `actionTitle` / `transcriptAvailableNote` / `loginSteps`（Task 3）、`AppModel.justSaved`・`readiness`（Task 8）、`ReadinessActionButton`・`AppShell.showSettings`（Task 9・10）、`ReadinessPresentation.abbreviate`、`AppPaths.tracksDirectory(_:)`
- Produces: `struct FailureBand: View`（`row`・`item` を受け、`source` が nil なら何も出さない）

- [ ] **Step 1: 画面を書く**
  - 処理中（`ProcessingDetailView`）: 見出しを `ProcessingPresentation.heading(stage: queueItem?.stage ?? "")`。文字起こし中は右に `engineNote(stage:model: model.readiness.model)` を `.secondary` で。本文の先頭に `ProcessingPresentation.explainer`。再試行待ち（`queueItem?.notBefore != nil`）なら上に `FailureBand`（黄色）
  - 短い録音: `StatusHeader` の `model.prompts` のうち `.recordingTooShort(id)` は `ShortRecordingCopy.band(seconds: <その行の durationSeconds>)` と［作る］（`.notice(.transcribeTooShort(id))`）［削除］（`.notice(.discardTooShort(id))`）。ほかの prompt は今のまま `NoticeContent`。`TooShortView` はボタンを外し、`DurationText.spoken` の長さと「上の帯から選んでください」だけ
  - 失敗（`MinutesMissingView`）: 先頭に `FailureBand`（赤。`tone == .waiting` は黄色）: `"\(what) — \(why)"` と `actions` のボタン（`actionTitle`）。確定版の文字起こしがあれば本文の上に `transcriptAvailableNote`。旧「議事録 未生成」の行と「再実行」ボタンは `FailureBand` に置き換える。ボタンの動作: `.installGuide` → `.installGuide`、`.redetectClaudeAndRerun` → `.redetectClaudeAndRerun(id)`、`.rerun` → `.notice(.retry(id))`、`.loginGuide` → `NSAlert`（`loginSteps`、OK のみ）、`.revealAudio` → `NSWorkspace.shared.activateFileViewerSelecting([env.paths.tracksDirectory(id)])`、`.delete` → 既存の削除確認（`CompletedDetailView` と同じ文言）の後 `.delete(id)`、`.changeOutputFolder` → `shell.showSettings(.general, using:)`、`.openSystemSettings` → `PrivacyPane.microphone` を開く。`outputFolderPath` は `model.readiness.outputFolder.path`
  - 完了（`CompletedDetailView`）: `model.justSaved?.id == id` なら先頭に緑の帯 `ProcessingPresentation.savedBand(path:home:)`。操作行に「Finder で表示」（`folder`。`NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])`、`filePath == nil` なら無効）を常設。「Obsidian で開く」は X38 の判定で Obsidian が無ければ**出さない**
  - 一覧の行: 長さは `DurationText.list(seconds: row.durationSeconds, minutes: row.durationMinutes)`
- [ ] **Step 2: ビルドを確かめる** — Run: `swift build && scripts/build-app.sh` → Expected: 成功
- [ ] **Step 3: 起動して確かめる（osascript）** — 新しい `AUTONOTE_DATA_DIR` に Task 9 の失敗ジョブのフィクスチャと c3d4 の manifest を置いて起動し、c3d4 を選ぶ → 静的テキスト「文字起こしに失敗しました — 文字起こしエンジンが途中で止まりました」とボタン「再実行」。どの静的テキストにも `_` を含む英字の識別子が無い。`autonote start` → 10 秒で `autonote stop` → 一覧の新しい行に「秒」、帯に「の録音です。1 分未満なので自動では処理しません。」とボタン「作る」「削除」。アプリを終了して起動し直しても帯が残る。完了のフィクスチャ（a1b2）を選ぶと「Finder で表示」がある
- [ ] **Step 4: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed。`git add Sources/AutoNoteApp/MainWindow && git commit -m "feat(app): stage headings, short-recording band, failure bands and saved-minutes band"`

---

### Task 12: メニュー・設定（⚠ 項目、ホットキー表記、一般タブで開く、保存先の既定）と E2E 07.3

**Files:**
- Modify: `Sources/AutoNoteApp/MenuBarContent.swift`、`Sources/AutoNoteApp/Settings/SettingsView.swift`、`Sources/AutoNoteApp/Settings/GeneralTab.swift`、`Sources/AutoNoteApp/MainWindow/StatusHeader.swift`（「設定を開く」を一般タブへ）、`scripts/e2e-check.sh`

**Interfaces:**
- Consumes: `MenuItem.readinessIssue` / `.startRecording(shortcut:)` / `.stop(shortcut:)` / `.pause(shortcut:)`・`KeyCombo.keyName`（Task 4）、`AppShell.settingsTab`・`showSettings(_:using:)`（Task 9）、`FirstRunDefaults.outputFolder(forInput:…)`・`defaultOutputFolder`（Task 2）、`ReadinessPresentation.abbreviate`
- Produces: `extension KeyboardShortcut { init?(_ combo: KeyCombo) }`（`MenuBarContent.swift`。`keyName` が 1 文字のときだけ。修飾は ctrl → `.control`、option → `.option`、shift → `.shift`、cmd → `.command`。F キーなどは nil で表記なし）

- [ ] **Step 1: E2E 項目を書く** — `check_menu_no_folder_warning`（`CURRENT="07.3 メニューに「保存先が見つかりません」が出ない"`）: `app_or_skip`。osascript で `click menu bar item 1 of menu bar 2`、0.5 秒待って `name of every menu item of menu 1 of menu bar item 1 of menu bar 2` を読み、`key code 53` で閉じる。名前に「録音開始」があり「保存先が見つかりません」が無ければ PASS。権限エラー（項目 7b と同じ判定）は SKIP。CHECKS の 07.2 の直後
- [ ] **Step 2: 失敗を確かめる** — Run: `scripts/build-app.sh && scripts/e2e-check.sh` → Expected: 07.3 は PASS か SKIP（既定の保存先があるので出ない。新しい ⚠ 項目の描き方を変える前の基準）。ほかは 0 failed
- [ ] **Step 3: 実装する**
  - メニュー: `.startRecording(shortcut:)` / `.stop` / `.pause` は `KeyboardShortcut(combo)` があれば `.keyboardShortcut(_:)` を付ける。`.readinessIssue(.outputFolder, title)` は押せるボタンで `shell.showSettings(.general, using: openSettings)`、`.readinessIssue(.claude, title)` は `shell.open(AppShell.mainWindowID)`（空状態の準備カード、または帯の［入れ方を見る］［もう一度探す］へ）。最初の ⚠ 項目の前に `Divider()`。`.openLatestMinutes(enabled: false)` の表記は「最新の議事録を開く（まだありません）」。「設定…」も `shell.showSettings(.general, using: openSettings)`
  - 設定: `SettingsView` の `TabView(selection: $shell.settingsTab)`（各タブに `.tag(SettingsTab.…)`）。`AppShell` は `@Observable` なので `@Bindable` で束ねる
  - 一般タブ: 見出しとフィールド名を「保存先」に。空のときのプレースホルダは `ReadinessPresentation.abbreviate(FirstRunDefaults.defaultOutputFolder(paths: env.paths, isDataDirectoryOverridden: env.isDataDirectoryOverridden).path(percentEncoded: false), home: NSHomeDirectory())`。保存は `FirstRunDefaults.outputFolder(forInput:…)` の値を入れ（空なら既定。nil にしない）、既定パスなら保存の前にフォルダを作る（`createDirectory(withIntermediateDirectories: true)`、失敗は `saveState = .failed("保存先を作れませんでした")`）
  - `StatusHeader` に残る「設定を開く」系のボタンも `showSettings(.general, …)`
- [ ] **Step 4: 通過を確かめる** — Run: `swift test && scripts/build-app.sh && scripts/e2e-check.sh` → Expected: 0 failed（07.3 は PASS、アクセシビリティ権限が無い環境だけ SKIP）
- [ ] **Step 5: 実機で一周を確かめる（osascript）** — 新しい `AUTONOTE_DATA_DIR` で起動（`consent_notice_shown: true`。claude はログイン済みのものを `claude_path` に）→「ウィンドウを開く」→ ツールバーの「録音を開始」→ `say -v Kyoko` で 90 秒ほど読み上げ → 「停止」→ ウィンドウを開いたまま待つ。議事録ができたら、その会議が選ばれて「議事録を保存しました — 」の帯が出ること（ウィンドウが前面に出ないこと: `frontmost of process "AutoNoteApp"` が操作前と同じ）。次に `claude_path` を `"/nonexistent/claude"` にして同じ手順（30 秒 + `autonote` で短い録音の「作る」）→「議事録を作れませんでした — Claude Code（claude）が見つかりません」とボタン「入れ方を見る」「もう一度探して再実行」。メニューのショートカット表記（⌃⌥R）と「最新の議事録を開く（まだありません）」も読む。結果を報告に書く（受け入れは Lead）
- [ ] **Step 6: コミット** — `git add Sources/AutoNoteApp scripts/e2e-check.sh && git commit -m "feat(app): readiness items and shortcut hints in the menu, settings open on the general tab, default 保存先 (E2E 07.3)"`
