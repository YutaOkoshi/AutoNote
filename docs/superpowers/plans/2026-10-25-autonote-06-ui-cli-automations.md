# AutoNote 計画 06: 画面・CLI・Automations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 計画 01〜05 のサービスをつなぎ、メニューバー・メインウィンドウ・設定画面・通知・グローバルショートカット・ログイン時起動、UNIX ソケット経由の CLI `autonote`、議事録生成後の Automations を作って、要件書 §4.1 の流れを利用者が端から端まで使える状態にする。

**Architecture:** 画面に依存しない部分（ソケットの JSON 行プロトコル、サーバーとクライアント、CLI の解釈と表示、Automations、サービスの窓口 `*Port` とアダプタ、計画をまたぐ配線 `AppWiring`、UI 用の状態集約 `AppModel` と表示規則）はすべて `AutoNoteCore` に置き、フェイクで Swift Testing にかける。`AutoNoteApp` には SwiftUI の画面、`UNUserNotificationCenter`・Carbon ホットキー・`SMAppService` をつなぐ薄いコード、具体のサービスを組み立てる `AppEnvironment.make` だけを置く。ソケットの要求は `CommandRouter`（MainActor に乗らない）がサービスへ直接渡すので、画面がモーダル表示中でも CLI は止まらない。

**Tech Stack:** Swift 6 / SwiftUI（`MenuBarExtra`、`Window`、`Settings`）/ Observation / POSIX の UNIX ドメインソケット / UserNotifications / Carbon `RegisterEventHotKey` / ServiceManagement `SMAppService.mainApp` / `posix_spawn`（Automations）/ Swift Testing / bash（scripts）

**Spec:** `docs/superpowers/specs/2026-10-24-autonote-design.md`（要件書。正）と `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md`（計画 01〜06 の共通契約。名前と形はここに従う）

## Global Constraints

- 最低 OS: macOS 26.0。`Package.swift` の platforms は `.macOS("26.0")`、`swift-tools-version: 6.2`、`swiftLanguageModes: [.v6]`。ツールチェーンは Swift 6.3（計画 00 と同じ）
- `autonote` CLI や `AutoNoteApp` から使う `AutoNoteCore` の型・関数は `public` にする（同じパッケージでも別ターゲットからは見えない）
- Intel（x86_64）と Apple Silicon（arm64）の両方でビルド・動作すること。機種依存の分岐は実行時判定（`isAvailable` など）で行い、`#if arch` で機能を落とさない
- 署名: 自己署名証明書 `AutoNote Dev`、Bundle ID `com.yutaokoshi.autonote`。`scripts/build-app.sh` を使う。App Sandbox なし、Hardened Runtime なし
- 音声・文字起こし・議事録・個人の機材識別子（MAC アドレス）をリポジトリにコミットしない。テストのフィクスチャは架空の内容にする
- 音声はローカルから出ない。外部へ渡すのは `claude -p` への文字起こしテキストだけ（要件書 G9）
- 共有する型とプロトコルは本書 §3・§4 の名前と形を使う。変えるなら本書を先に直す
- 利用者の手が要る手順は「👤 利用者」と明記し、実装者はそこで止めて依頼する
- 各タスクは TDD（失敗するテスト → 実装 → 通過 → コミット）。ハードウェアが要る部分だけ手動確認手順を書く
- コミットメッセージは英語の Conventional Commits。タスクごとにコミット。push はしない
- 実装者はタスク完了前に `scripts/e2e-check.sh` を回し、結果を報告に含める

（「本書」は overview を指す。本計画が作る型・関数で CLI か App から使うものはすべて `public`。Interfaces では `public` を省いて書く箇所もあるが、読み替える。）

## Review Focus

要件書から読み取れるが、素直に作ると誰のテストにも引っかからず、利用者が踏みやすいもの。各行のテストは担当タスクに入れてある。

1. ソケットのパスが `sun_path` の上限（104 バイト、終端 NUL を含む）を超える（ホームが長い、`AUTONOTE_DATA_DIR` を深い場所にした）。黙って切り詰めず、分かるエラーで止まる（Task 7 `pathTooLongIsRejected`）
2. アプリが起動できない（`open -b` が失敗する、起動しても 10 秒以内にソケットが現れない）ときに CLI がずっと待ち続ける。10 秒で終了コード 1 と理由を出す（Task 7 `clientTimesOutWhenAppNeverAppears`・`launcherFailureIsReported`）
3. Automation のコマンドが子プロセスを残す、または SIGTERM を無視する。タイムアウトで zsh だけ止めても孫が生き残る。プロセスグループごと止め、失敗として記録する（Task 4 `timeoutKillsWholeProcessGroup`・`sigtermIgnoredIsKilled`）
4. Automation のコマンドが 64KB を超える出力を書く。パイプが詰まってタイムアウトまで固まる。出力はファイルへ直接書かせる（Task 4 `largeOutputDoesNotBlock`）
5. 会議ファイルのパスに日本語・空白・`#`・`&` が入る。「Obsidian で開く」の URL が壊れて別のノートを開く、または開かない（Task 11 `obsidianLinkEncodesEverythingButUnreserved`）

---

## 使う計画 01〜05 の API（Consumes）

字面は overview §3・§4・§8b と各計画の Produces から写した。名前は overview を優先し、overview に無いものは各計画の現在の文面に従う。画面と CLI は Task 8 の `*Port` にだけ依存させ、具体型に触るのは Task 8 のアダプタと Task 13 の組み立てだけにする（計画 05 は改訂中なので、init の引数や `enqueue` が throws かどうかが変わってもこの 2 か所で吸収する）。

| 計画 | 型・関数 | 使うタスク |
|---|---|---|
| 01 | `AppPaths.resolve(environment:)`（`AUTONOTE_DATA_DIR`）・`socketFile`・`automationsFile`・`logsDirectory`・`modelsDirectory`・`queueJobsDirectory`・`transcriptFile(_: MeetingID, _: TranscriptKind)`・`minutesFile(_:)`・`createBaseDirectories()`、`enum TranscriptKind { live, raw, final }` | 2・5・8・13 |
| 01 | `Settings`（overview §3 の一覧。本計画は**書き換えない**）、`Shortcuts { bookmark, toggleRecording, togglePause: String }`（既定 `"ctrl+option+b"` `"ctrl+option+r"` `"ctrl+option+p"`）、`SummarizerKind.claudeCode`、`actor SettingsStore(paths:)` の `load()`・`save(_:)`・`update(_:)` | 11・13・15 |
| 01 | `actor ManifestStore(paths:)` の `load(_:)`・`all()`・`update(_:_:)`、`Manifest`・`MeetingStatus`・`MinutesOutput`・`Transcript`・`Utterance`・`Bookmark`・`TimelineTime` | 5・8 |
| 01 | `actor VaultWriter(outputFolder:paths:now:)` の `write(_:policy:renameToMatchTitle:) -> VaultWriteOutcome`（`.written(URL)` / `.conflict(URL)`）・`rebuildIndex()`・`record(for:) -> VaultWriteRecord?`（`relativePath`）、`OverwritePolicy { ifUnchanged, force }`、`MeetingDocument(manifest:transcript:minutes:frontmatter:appVersion:timeZone:)`、`FrontmatterTemplate(text:)`・`defaultText`・`requiredKeys`、`VaultScanner.scan(outputFolder:) -> [IndexEntry]`、`IndexEntry`（`meetingID` `date` `start` `title` `durationMinutes` `firstLine` `status` `linkPath`） | 5・8・14 |
| 01 | `actor PortableConfigStore(paths:outputFolder:)` の `isOutputAvailable`・`sync()`・`read(_:)`・`write(_:_:)`、`PortableFile { dictionary, prompt, frontmatter, devices }`、`DictionaryFile.parse(_:)`・`render()`・`defaultMarkdown`、`Replacement` | 8・13・15 |
| 01 | TestSupport `Samples.manifest`・`FakeLiveTranscriber(script:)`（`fedChunks`）・`FakeError`、フィクスチャ `Tests/Fixtures/meetings/20261024-1400-a1b2/{manifest.json, minutes.json}`、E2E の `AUTONOTE_CLI` | 5・8・13・16 |
| 02 | `actor RecordingSession` の `static live(paths:settings:clock:)`・`events()`（呼ぶたびに新しい購読）・`audio(for: Track) -> AsyncStream<AudioChunk>`、`RecordingEvent`（overview §3 の 10 case）、`StopReason { manual, deviceGone, diskFull, appTerminating }`、`SilenceWarning { track, message }` | 5・11・12・13 |
| 02 | `CrashRecovery(paths:manifests:)` の `findInterrupted(excluding:)`・`recover(_:) -> Manifest`・`discard(_:)`、`AudioImporter(paths:manifests:)` の `supportedExtensions`・`importFile(_:startedAt:language:progress:) -> Manifest`、`AVMicrophonePermission().status()`、`WAVFile.header(sampleRate:channels:bitsPerSample:dataBytes:)` | 8・13・14 |
| 03 | `RecorderState`、`RecorderSnapshot`（`state` `meetingID` `startedAt` `deviceName` `deadline` `isManual` `language` `banner` `canCancelCountdown`）、`actor AutoRecordCoordinator(monitor:registry:recorder:notifier:timer:config:now:)` の `run()`・`current()`・`snapshots()`・`manualStart(language:)`・`stop()`・`pause()`・`resume()`・`cancelCountdown()`・`bookmark(note:)`・`setLanguage(_:)`・`handle(_: UserNoticeAction)`・`static config(from:) -> AutoRecordConfig`、`AutoRecordError.notRecording`、`RecordingSessionControl(session:)` | 8・11・13・15 |
| 03 | `UserNotifier`（`post(_:)`・`withdraw(id:)`）、`UserNotice`（overview §3 の 14 case と `id`）、`UserNoticeAction`（11 case）、`RegisterAnswer`、`DeviceNoticeCopy`、TestSupport `FakeUserNotifier`（`posted`・`withdrawn`） | 5・11・12・13 |
| 03 | `actor DeviceMonitor(hardware:power:timer:)` の `connected()`、`actor DeviceRegistry(storage:mac:)` の `reload()`・`entries()`・`register(_:startOnModelMatchDefault:)`・`ignore(_:)`・`remove(entryID:)`・`setStartOnModelMatch(entryID:_:)`、`RegisteredDevice`、`PortableDevicesStorage(store:paths:)`、`SystemMacIdentityProvider`、`CoreAudioHardware`・`WorkspaceSleepWakeObserver`・`TaskTimerScheduler` | 13・15 |
| 04 | `EngineCatalog(machine:speech:installedModels:)` の `entries(role:language:) -> [EngineEntry]`・`resolve(role:language:override:)`、`EngineChoice`（`kind` `model` `displayName` `static fromSettings(kind:model:role:machine:)`）、`EngineKind { dictation, speech, whisper }`、`EngineRole { live, batch }`、`EngineEntry { choice, available, reason }`、`actor ModelManager(directory:)` の `installed()`・`download(_:progress:)`・`delete(_:)`、`WhisperModelCatalog.all`、`TranscriberFactory(models:machine:)`、`BatchGate`、`FinalTranscriptionRunner(transcriber:engineName:paths:gate:)`、`AppleSpeechCapabilities`、`MachineKind` | 13・15 |
| 04 | `actor LiveFeed` の `init(transcribers:replacer:liveJSON:engineName:)`・`static make(settings:catalog:factory:dictionary:liveJSON:)`・`start(language:hints:) -> AsyncStream<[Utterance]>`（確定＋部分＋印を時刻順・置換済みで毎回全体）・`feed(_:)`・`pause(at:)`・`resume(at:)`・`bookmark(_:)`・`finish()`（`live.json` を必ず書く）・`static isMarker(_:)` | 11・13 |
| 05 | `QueueStage`（overview §4）、`Job`（`meeting` `generation` `summaryFailure` ほか）、`StageContext`、`StageName.automations`、`actor PostProcessingQueue(paths:stages:activity:)` の `start()`・`stop()`・`enqueue(_:)`・`snapshot()`・`snapshots()`・`regenerate(_:)`・`resolveOverwrite(_:overwrite:)`・`acceptShortRecording(_:)`・`delete(_:)`、`QueueSnapshot { jobs: [JobProgress], pausedForRecording }`、`JobProgress`（`meetingID` `stage` `state` `progress` `lastError`）、`RecordingActivity`（05 が `events()` から作るアダプタ）、`TranscribeStage`・`SummarizeStage`・`WriteVaultStage`・`UpdateIndexStage`、`RetentionScheduler`、`DefaultPrompt.instructions`、`SummaryFailure.Kind.notLoggedIn` | 5・8・13・15 |

## この計画で決めたこと

- グローバルショートカットは Carbon `RegisterEventHotKey`。アクセシビリティ（入力監視）許可が要らず、キーを前面アプリに漏らさない。`NSEvent.addGlobalMonitorForEvents` は許可が要り、キーを止められないので使わない。設定値は計画 01 の `Settings.shortcuts`（文字列）を `KeyCombo(parsing:)` で読み、変えたら `KeyCombo.description` の文字列で書き戻す。`Settings` の項目は足さない
- 猶予中は「取り消す」を出さない（overview §8b。§5.9 を採る）。Task 1 で要件書 §15.1 を直す。猶予中は「機材が外れました。N 秒後に停止」と「停止」（即停止）を出す
- 通知に音を付けない（overview §3）。許可は `.alert` だけ求め、`willPresent` は `[.banner, .list]`、`sound` は nil。「押すまで残る通知」は `Info.plist` の `NSUserNotificationAlertStyle = alert` で既定の表示スタイルを「通知パネル」にし、要確認の通知（短すぎる録音・中断した録音・上書き確認）はメインウィンドウの帯にも同じボタンで出す
- 他の計画は通知を出さないので、機材以外の 10 case は本計画が出す。議事録の完了（`minutesGenerated`・`transcriptOnly`・`claudeNotLoggedIn`）は最後の段階 `AutomationsStage` が manifest の status を見て出す。録音・待ち行列・出力フォルダ由来は `NoticeRelay` と `AppWiring`
- `AUTONOTE_DATA_DIR` は計画 01 の `AppPaths.resolve(environment:)` がアプリと CLI の両方で読む。差し替え中の CLI はアプリを自動起動しない（`open -b` では環境変数を渡せないため）
- 初回注意書きとクラッシュ復旧の確認はモーダルにしない（起動直後の CLI と E2E を止めないため）。注意書きは小さなウィンドウ、復旧は `interruptedRecordingFound` 通知とウィンドウの帯
- `LSUIElement` のアプリはメニューバーにファイルメニューを出せないので、要件書 §10 の「ファイルメニュー」はメインウィンドウのツールバーの「音声ファイルを取り込む…」で代える
- `AutoNoteCore` に `Automations/` と `Presentation/` のフォルダを足す。`Package.swift` は変えない（Carbon・ServiceManagement・UserNotifications は自動リンク）

## ファイル構成

`Sources/AutoNoteCore/` に `Automations/`（Task 3〜5）と `Presentation/`（Task 8・11〜13・15）を新しく作り、`IPC/`（Task 2・6・7・9・10）を埋める。Port のフェイクは `Sources/AutoNoteTestSupport/FakePorts.swift`（Task 8・13）。`Sources/AutoNoteApp/` は画面と OS をつなぐコードと組み立てだけ（Task 12〜15）。テストは `Tests/AutoNoteCoreTests/{IPC,Automations,Presentation}/`。各タスクの Files が正。

テストでソケットを作るときは `FileManager.temporaryDirectory`（`/var/folders/…` で長い）ではなく `/tmp/an-<8 桁の hex>/` を使う（Review Focus 1 のため）。

---

### Task 1: 要件書 §15.1 の「取り消す」をカウントダウン中だけにする

overview §8b の裁定。§15.1 は「カウントダウン中・猶予中のみ」、§5.9 の状態表は猶予中に「「取り消す」ボタンは出さない」で矛盾しているので §5.9 に合わせる。コードの変更はないので TDD の対象外。

**Files:**
- Modify: `docs/superpowers/specs/2026-10-24-autonote-design.md`（§15.1 の 1 行）

**Interfaces:**
- Consumes: なし
- Produces: 要件書 §15.1 の確定した文面（Task 11 の `MenuBarPresentation` と Task 14 の帯がこれに従う）

- [ ] **Step 1: 直す行を確かめる** — Run: `grep -n '「取り消す」（カウントダウン中・猶予中のみ）' docs/superpowers/specs/2026-10-24-autonote-design.md` → Expected: 1 行だけ（§15.1、今の版で 646 行目）
今の行:
```text
- メニュー: 録音開始・停止・一時停止、ブックマーク、「取り消す」（カウントダウン中・猶予中のみ）、ウィンドウを開く、最新の議事録を開く、設定、終了
```
- [ ] **Step 2: 書き換える** — その 1 行を次にする（他の行は変えない）:
```text
- メニュー: 録音開始・停止・一時停止、ブックマーク、「取り消す」（カウントダウン中のみ。猶予中は出さない。§5.9）、ウィンドウを開く、最新の議事録を開く、設定、終了
```
- [ ] **Step 3: 確かめる** — Run: `grep -c 'カウントダウン中・猶予中' docs/superpowers/specs/2026-10-24-autonote-design.md; grep -c '「取り消す」（カウントダウン中のみ。猶予中は出さない。§5.9）' docs/superpowers/specs/2026-10-24-autonote-design.md; scripts/e2e-check.sh --quick` → Expected: `0`、`1`、E2E は 0 failed
- [ ] **Step 4: コミット** — `git add docs/superpowers/specs/2026-10-24-autonote-design.md && git commit -m "docs: menu cancel item is countdown-only (spec 15.1, follows 5.9)"`

---

### Task 2: Bundle ID と証明書名の一本化（`scripts/config.sh`）

計画 00 最終レビュー M4。Bundle ID と証明書名が 3 本のスクリプトと Swift に散っているのを一か所にする。

**Files:**
- Create: `scripts/config.sh`
- Create: `Sources/AutoNoteCore/IPC/AppIdentity.swift`
- Modify: `scripts/build-app.sh`（`CERT_NAME` `BUNDLE_ID` の 2 行）、`scripts/e2e-check.sh`（同 2 行と確認項目の追加）、`scripts/make-dev-cert.sh`（`CERT_NAME` の 1 行）
- Test: `Tests/AutoNoteCoreTests/IPC/AppIdentityTests.swift`

**Interfaces:**
- Consumes: `AppPaths.resolve(environment:)`（計画 01。データ領域の差し替えはこれが持つ。本タスクは同じキーを判定に使うだけ）
- Produces: `public enum AppIdentity { public static let bundleID: String /* "com.yutaokoshi.autonote" */; public static let dataDirectoryEnvironmentKey: String /* "AUTONOTE_DATA_DIR" */; public static func isDataDirectoryOverridden(_ environment: [String: String]) -> Bool }`。shell 変数 `AUTONOTE_BUNDLE_ID`、`AUTONOTE_CERT_NAME`

- [ ] **Step 1: 失敗するテストと E2E 項目を書く**
```swift
@Test func overrideDetectionMatchesAppPaths() {
    let env = ["AUTONOTE_DATA_DIR": "/tmp/an-test"]
    #expect(AppIdentity.isDataDirectoryOverridden(env) && AppPaths.resolve(environment: env).root.path == "/tmp/an-test")
    #expect(!AppIdentity.isDataDirectoryOverridden([:]) && !AppIdentity.isDataDirectoryOverridden(["AUTONOTE_DATA_DIR": ""]))
    #expect(AppIdentity.bundleID == "com.yutaokoshi.autonote")
}
```
`scripts/e2e-check.sh` に `check_identity_consistency`（`CURRENT="06.1 Bundle ID の一本化"`）を足し、CHECKS の先頭に置く。`scripts/config.sh` を source し、`Resources/Info.plist` の `CFBundleIdentifier`（PlistBuddy）と `AppIdentity.swift` の `bundleID`（sed）が `AUTONOTE_BUNDLE_ID` と一致すれば PASS。また `build-app.sh` と `make-dev-cert.sh` に `com.yutaokoshi.autonote` と `"AutoNote Dev"` の直書きが残っていないことを `grep -n` で確かめる（残っていれば FAIL。`e2e-check.sh` は検索語そのものを含むので対象にせず、Step 3 で目で直す）。
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AppIdentityTests; scripts/e2e-check.sh --quick` → Expected: テストは `cannot find 'AppIdentity' in scope` でビルド失敗。06.1 は `scripts/config.sh` が無いので FAIL
- [ ] **Step 3: 実装する**
`scripts/config.sh` は次の 2 変数だけを持つ（source 専用。実行ビットは付けない）:
```bash
# Bundle ID と署名証明書名の唯一の定義。build-app.sh / e2e-check.sh / make-dev-cert.sh が source する
AUTONOTE_BUNDLE_ID="com.yutaokoshi.autonote"
AUTONOTE_CERT_NAME="AutoNote Dev"
```
3 本のスクリプトは自分の置き場所から `config.sh` を source し、`CERT_NAME="${AUTONOTE_CERT_NAME}"` `BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"` とする。`build-app.sh` は Info.plist を写した後、`CFBundleIdentifier` が `AUTONOTE_BUNDLE_ID` と違えばエラーで止まる。`isDataDirectoryOverridden` は値が空でないときだけ true（`AppPaths.resolve` と同じ判定にする）。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AppIdentityTests && scripts/e2e-check.sh` → Expected: PASS。E2E は 06.1 を含め 0 failed（計画 00 の 2〜5 も署名が変わらず PASS）
- [ ] **Step 5: コミット** — `git add scripts/config.sh scripts/build-app.sh scripts/e2e-check.sh scripts/make-dev-cert.sh Sources/AutoNoteCore/IPC/AppIdentity.swift Tests/AutoNoteCoreTests/IPC/AppIdentityTests.swift && git commit -m "chore: single source for bundle id and cert name (scripts/config.sh)"`

---

### Task 3: Automations の定義ファイル（`automations.json`）

**Files:**
- Create: `Sources/AutoNoteCore/Automations/AutomationDefinition.swift`, `Sources/AutoNoteCore/Automations/AutomationsFile.swift`
- Test: `Tests/AutoNoteCoreTests/Automations/AutomationsFileTests.swift`

**Interfaces:**
- Consumes: なし（`AppPaths.automationsFile` は呼び手が渡す）
- Produces:
  - `public enum AutomationTrigger: String, Codable, Sendable, CaseIterable { case minutesGenerated = "minutes_generated", transcriptOnly = "transcript_only", recordingStarted = "recording_started", recordingStopped = "recording_stopped" }`
  - `public struct AutomationDefinition: Codable, Equatable, Sendable, Identifiable { public var name: String; public var enabled: Bool; public var on: AutomationTrigger; public var command: String; public var timeoutSec: Int /* 既定 300 */; public var id: String { name } }`（JSON キーは `name` `enabled` `on` `command` `timeout_sec`）
  - `public struct LoadedAutomation: Equatable, Sendable { public var definition: AutomationDefinition; public var isRunnable: Bool; public var problem: String? }`
  - `public struct AutomationsLoadResult: Equatable, Sendable { public var items: [LoadedAutomation]; public var warnings: [String]; public var disabledByPermission: Bool }`
  - `public struct AutomationsFile: Sendable { public init(url: URL); public func load() -> AutomationsLoadResult; public func save(_ defs: [AutomationDefinition]) throws; public func export(to: URL) throws; public func importReplacing(from: URL) throws -> AutomationsLoadResult }`

- [ ] **Step 1: 失敗するテストを書く**
要件書 §14.6 の例を `Tests/AutoNoteCoreTests/Automations/` のテスト内に文字列で持つ（架空の内容なのでそのまま使ってよい）。
```swift
@Test func loadsSpecExample() throws {   // §14.6 の 2 件
    let r = AutomationsFile(url: try write(specExample, mode: 0o600)).load()
    #expect(r.items.map(\.definition.name) == ["Slack に要約を投稿", "Claude で Next Action を整理"])
    #expect(r.items.map(\.definition.timeoutSec) == [60, 300])
    #expect(r.items.allSatisfy { $0.isRunnable && $0.definition.on == .minutesGenerated })
    #expect(r.warnings.isEmpty && !r.disabledByPermission)
}
@Test func missingTimeoutDefaultsTo300()      // timeout_sec なし → 300
@Test func missingFileIsEmptyWithoutWarning() // items == [], warnings == []
@Test(arguments: [0o664, 0o646, 0o666]) func writableByOthersDisablesAll(mode: Int) throws {
    let r = AutomationsFile(url: try write(specExample, mode: mode)).load()
    #expect(r.disabledByPermission && r.items.allSatisfy { !$0.isRunnable })
    #expect(r.warnings == ["automations.json が自分以外から書き込める権限になっているため、Automations を無効にしました（chmod 600 で直せます）"])
}
@Test func invalidJSONWarnsAndDoesNotThrow()  // "[{" → items == [], warnings.count == 1、先頭が "automations.json を読めません"
@Test func unknownTriggerMarksOnlyThatEntry() // "on": "meeting_ended" → その 1 件だけ isRunnable == false、problem == "きっかけ meeting_ended は使えません"
@Test func duplicateNameMarksSecond()         // 同名 2 件 → 2 件目 problem == "同じ名前の Automation が先にあります"
@Test func saveWrites0600AndRoundTrips()      // save → stat の権限 0o600、load で同じ定義
@Test func importReplacingValidatesFirst()    // 壊れた JSON の取り込みは throw し、元のファイルは変わらない
```
`write(_:mode:)` はテスト内のヘルパーで、一時フォルダに書いて `chmod` する。
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AutomationsFileTests` → Expected: `cannot find 'AutomationsFile' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
権限は `stat` で見る: `st_mode & (S_IWGRP | S_IWOTH) != 0` または `st_uid != getuid()` なら全件を `isRunnable = false` にする。定義ごとの判定（未知のきっかけ、同名、`command` が空、`timeout_sec` が 1 未満）は `problem` に理由を入れて `isRunnable = false`。未知のきっかけでも他の件は読めるよう、配列の要素は 1 件ずつ `JSONSerialization` 経由で decode する。`save` は一時ファイルに 0600 で書いてから `rename`（原子的）。`enabled == false` は `isRunnable == false`、`problem == nil`。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AutomationsFileTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Automations Tests/AutoNoteCoreTests/Automations && git commit -m "feat: load and save automations.json with permission check"`

---

### Task 4: `AutomationRunner`（実行・タイムアウト・ログ・二重実行防止）

**Files:**
- Create: `Sources/AutoNoteCore/Automations/AutomationContext.swift`, `AutomationRunRecord.swift`, `ProcessGroupSpawner.swift`, `AutomationRunner.swift`
- Test: `Tests/AutoNoteCoreTests/Automations/AutomationRunnerTests.swift`

**Interfaces:**
- Consumes: `AutomationDefinition`, `AutomationTrigger`（Task 3）、`MeetingID`（計画 01）
- Produces:
  - `public struct AutomationContext: Equatable, Sendable { public var event: AutomationTrigger; public var meetingID: MeetingID; public var file: URL?; public var title: String; public var date: String /* "YYYY-MM-DD" */; public var start: String /* "HH:MM" */; public var minutesJSON: URL?; public func environment() -> [String: String]; public func stdinJSON() throws -> Data }`
  - `public struct AutomationRunRecord: Codable, Equatable, Sendable { public var name: String; public var event: AutomationTrigger; public var meetingID: String; public var startedAt: Date; public var durationSeconds: Double; public var exitCode: Int32?; public var timedOut: Bool; public var skippedReason: String?; public var logDirectory: String; public var succeeded: Bool { get } }`
  - `public actor AutomationRunner { public static let defaultShell: [String] /* ["/bin/zsh", "-lc"] */; public init(logsDirectory: URL, ledgerFile: URL, shell: [String] = defaultShell, killGrace: Duration = .seconds(5), maxLogRuns: Int = 200); public func run(_ def: AutomationDefinition, context: AutomationContext, dedupeKey: String?) async -> AutomationRunRecord; public func recentRuns(limit: Int) async -> [AutomationRunRecord]; public func records() -> AsyncStream<AutomationRunRecord> }`

- [ ] **Step 1: 失敗するテストを書く**
時間を測るテストはログインシェルの読み込みでぶれないよう `shell: ["/bin/zsh", "-fc"]` を渡す。`ctx` は `event: .minutesGenerated, meetingID: "20261024-1400-a1b2", file: /tmp/x/2026-10-24_1400_定例.md, title: "定例", date: "2026-10-24", start: "14:00", minutesJSON: /tmp/x/minutes.json`。
```swift
@Test func defaultShellIsZshLogin() { #expect(AutomationRunner.defaultShell == ["/bin/zsh", "-lc"]) }
@Test func passesEnvironmentAndStdin() async throws {
    let rec = await runner.run(def(#"printf '%s\n' "$AUTONOTE_EVENT" "$AUTONOTE_MEETING_ID" "$AUTONOTE_FILE" "$AUTONOTE_TITLE" "$AUTONOTE_DATE" "$AUTONOTE_START" "$AUTONOTE_JSON"; cat"#), context: ctx, dedupeKey: nil)
    let out = try String(contentsOf: URL(filePath: rec.logDirectory).appending(path: "stdout.txt"), encoding: .utf8)
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.prefix(7) == ["minutes_generated", "20261024-1400-a1b2", "/tmp/x/2026-10-24_1400_定例.md", "定例", "2026-10-24", "14:00", "/tmp/x/minutes.json"])
    // 8 行目以降が stdin の JSON。キーは event, meeting_id, file, title, date, start, json
    #expect(rec.exitCode == 0 && rec.succeeded)
}
@Test func absentFileAndJSONAreEmptyEnvAndNullJSON()   // file/minutesJSON nil → 環境変数は ""、stdin の "file" と "json" は null
@Test func nonZeroExitIsFailure()                      // "exit 3" → exitCode == 3、succeeded == false
@Test func timeoutKillsWholeProcessGroup() async throws {   // timeoutSec 1。孫プロセスの pid をファイルに書かせる
    let rec = await runner.run(def("sleep 30 & echo $! > \(pidFile.path); wait", timeout: 1), context: ctx, dedupeKey: nil)
    #expect(rec.timedOut && !rec.succeeded && rec.durationSeconds < 8 && kill(try readPID(pidFile), 0) == -1)   // 孫も止まっている
}
@Test func sigtermIgnoredIsKilled()                     // "trap '' TERM; sleep 30"、timeout 1、killGrace 1 秒 → timedOut、durationSeconds < 8
@Test func largeOutputDoesNotBlock()                    // "head -c 300000 /dev/zero | tr '\\0' a" → stdout.txt が 300000 バイト、timedOut == false
@Test func sameDedupeKeyRunsOnce()                      // 同じ key で 2 回 → 2 回目 skippedReason == "already_ran"、カウンタファイルは 1 行
@Test func ledgerSurvivesNewRunner()                    // 別インスタンス（同じ ledgerFile）でも skip
@Test func manualRunIgnoresLedger()                     // dedupeKey nil は何度でも走る
@Test func keepsOnlyNewestLogRuns()                     // maxLogRuns 3 で 5 回 → ログのフォルダは 3 つ、recentRuns(limit: 10).count == 3
@Test func resultJSONWritten()                          // logDirectory/result.json を decode すると返り値と同じ
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AutomationRunnerTests` → Expected: `cannot find 'AutomationRunner' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
- `ProcessGroupSpawner.spawn(arguments: [String], environment: [String: String], stdin: Data, stdoutFile: URL, stderrFile: URL) throws -> pid_t`: `posix_spawn` に `POSIX_SPAWN_SETPGROUP`（pgid = 子の pid）を付け、stdout・stderr は `posix_spawn_file_actions_addopen` でログファイルへ直接開く（パイプを使わない。Review Focus 4）。stdin はパイプで渡し、書き終えたら閉じる（コマンドが stdin を読まなくても詰まらないよう、書き込みは別スレッドで行い EPIPE を無視する）
- 待ち: `waitpid` を別スレッドで回し、`timeoutSec` を超えたら `kill(-pgid, SIGTERM)`、`killGrace` 後も残っていれば `kill(-pgid, SIGKILL)`。終了コードは `WEXITSTATUS`、シグナル終了は `exitCode = nil`
- 環境: `ProcessInfo.processInfo.environment` に `context.environment()` を重ねる
- ログ: `logsDirectory/<yyyyMMdd-HHmmss>-<meeting-id>-<name を英数字と - だけにしたもの>/` に `stdout.txt` `stderr.txt` `result.json`。`maxLogRuns` を超えたら古いフォルダから消す
- 二重実行防止: `ledgerFile`（JSON の文字列配列）に `dedupeKey` を**実行前に**記録する（途中でアプリが落ちても再実行しない。Slack への二重投稿を避ける［私の判断］）。actor なので実行は常に 1 本ずつ
- `records()` は実行が終わるたびに記録を流す（AppModel の「Automation 失敗」表示用）
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AutomationRunnerTests` → Expected: PASS（全体で 30 秒以内）
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Automations Tests/AutoNoteCoreTests/Automations && git commit -m "feat: run automations via zsh with timeout, logs and dedupe ledger"`

---

### Task 5: `AutomationsStage`（待ち行列の最後の段階）と録音のきっかけ

**Files:**
- Create: `Sources/AutoNoteCore/Automations/AutomationDispatcher.swift`, `AutomationsStage.swift`, `RecordingAutomationTrigger.swift`
- Test: `Tests/AutoNoteCoreTests/Automations/AutomationDispatcherTests.swift`

**Interfaces:**
- Consumes: `AutomationsFile`（Task 3）、`AutomationRunner`, `AutomationContext`（Task 4）、`QueueStage`・`Job`（`meeting` `generation` `summaryFailure`）・`StageContext`（`paths` `settings` `manifests`）・`StageName.automations`（overview §3・§4）、`Manifest`・`MeetingStatus`・`AppPaths.minutesFile(_:)`・`VaultWriter.record(for:)`（計画 01）、`RecordingEvent`（計画 02）、`UserNotifier`・`UserNotice`・`FakeUserNotifier`（計画 03）、`SummaryFailure.Kind.notLoggedIn`（計画 05）
- Produces:
  - `public struct AutomationDispatcher: Sendable { public init(file: AutomationsFile, runner: AutomationRunner, notifier: (any UserNotifier)?); public func dispatch(_ trigger: AutomationTrigger, context: AutomationContext, dedupeKey: String?) async -> [AutomationRunRecord] }`（`runOne` は `AppCommandError` を使うので Task 8 で足す）
  - `public enum AutomationContextBuilder { public static func make(event: AutomationTrigger, manifest: Manifest, file: URL?, minutesJSON: URL?, timeZone: TimeZone = .current) -> AutomationContext }`
  - `public struct AutomationsStage: QueueStage { public let name = StageName.automations; public init(dispatcher: AutomationDispatcher, notifier: (any UserNotifier)?, vault: @Sendable @escaping () async -> (folder: URL, writer: VaultWriter)?); public static func trigger(for status: MeetingStatus) -> AutomationTrigger?; public static func dedupeKey(_ job: Job) -> String; public static func completionNotice(manifest: Manifest, job: Job) -> UserNotice?; public func run(_ job: inout Job, context: StageContext) async throws }`
  - `public actor RecordingAutomationTrigger { public init(dispatcher: AutomationDispatcher, manifests: ManifestStore); public func handle(_ event: RecordingEvent) async }`

- [ ] **Step 1: 失敗するテストを書く**
`job(_:generation:)` はテスト内の補助で `Job(id:meeting:stages: StageName.all, …)` を作る。`stage(...)` は一時の `AppPaths` と出力フォルダ、`FakeUserNotifier` で組む。
```swift
@Test func triggerMapping() {
    #expect(AutomationsStage.trigger(for: .minutesGenerated) == .minutesGenerated && AutomationsStage.trigger(for: .transcriptOnly) == .transcriptOnly)
    #expect(AutomationsStage.trigger(for: .failed) == nil && AutomationsStage.trigger(for: .recorded) == nil)
}
@Test func dedupeKeyUsesGeneration() { #expect(AutomationsStage.dedupeKey(job("20261024-1400-a1b2", generation: 2)) == "20261024-1400-a1b2:2") }   // overview §3
@Test func regenerationRunsAgain() async throws   // 同じ generation で run 2 回 → 記録 1 件。generation 3 で run → 2 件（§14.5 再生成で再発火）
@Test func pathsFromAppPathsAndVaultRecord() async throws   // status minutesGenerated、vault-state の relativePath "Meetings/2026/x.md" → AUTONOTE_FILE == "<folder>/Meetings/2026/x.md"、AUTONOTE_JSON == paths.minutesFile(id).path。transcriptOnly → AUTONOTE_JSON == ""。Vault 未書き出し → AUTONOTE_FILE == ""
@Test func runsOnlyMatchingRunnableInFileOrder() async  // A(minutes) B(minutes, enabled false) C(transcript_only) D(minutes) → 記録の name == ["A", "D"]
@Test func failureDoesNotThrowAndNotifies() async throws // "exit 1" → run は投げない、posted に .automationFailed(name: "A", id)
@Test func completionNotices() {
    // minutesGenerated・title "定例" → .minutesGenerated(id, title: "定例")、title nil → title "（無題）"、transcriptOnly → .transcriptOnly(id)
    // transcriptOnly かつ job.summaryFailure == SummaryFailure.Kind.notLoggedIn.rawValue → .claudeNotLoggedIn(id)、failed・recorded → nil
}
@Test func permissionDisabledRunsNothing() async        // 0664 のファイル → 記録 0 件
@Test func contextFromManifest()   // startedAt 2026-10-24T05:00:00Z、title nil、timeZone Asia/Tokyo → title "", date "2026-10-24", start "14:00", file nil
@Test func recordingEventsFireStartedAndStoppedOnce() async   // handle: .started(id), .bookmarked(b), .stopped(m, .manual), .stopped(m, .manual) → recording_started 1 回、recording_stopped 1 回
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AutomationDispatcherTests` → Expected: `cannot find 'AutomationDispatcher' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
- `dispatch` は毎回 `file.load()` で読み直す（外で編集されても次の実行に効く）。`isRunnable && on == trigger` の件を配列順に `runner.run` し、各件の鍵は `"<dedupeKey>|<name>"`。失敗した件ごとに `notifier?.post(.automationFailed(name:, meetingID))`
- `AutomationsStage.run`: `context.manifests.load(job.meeting)` → `completionNotice` があれば `post`（他の計画は完了通知を出さないため。本計画の判断）→ `trigger(for: manifest.status)` が nil なら終わり → `file` は `vault()` の `writer.record(for:)?.relativePath` を `folder` に足したもの（無ければ nil）、`minutesJSON` は `trigger == .minutesGenerated` かつ `context.paths.minutesFile(id)` があるときだけ → `dispatch(trigger, context: AutomationContextBuilder.make(…), dedupeKey: dedupeKey(job))`。`dedupeKey` は `"\(job.meeting.rawValue):\(job.generation)"`。manifest が読めない・Automation が失敗した場合もログに残して**投げない**（§14.5「議事録の成否に影響しない」）
- `RecordingAutomationTrigger.handle`: `.started(id)` → `manifests.load(id)` で `recording_started`、`.stopped(manifest, _)` → `recording_stopped`。`file`・`minutesJSON` は nil。鍵は `"rec:<id>:<event>"`。他の事象は無視
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AutomationDispatcherTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Automations Tests/AutoNoteCoreTests/Automations && git commit -m "feat: automations queue stage, completion notices and recording triggers"`

---

### Task 6: ソケットのプロトコル（JSON 行）

**Files:**
- Create: `Sources/AutoNoteCore/IPC/IPCProtocol.swift`, `Sources/AutoNoteCore/IPC/WireTypes.swift`, `Sources/AutoNoteCore/IPC/LineCodec.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/IPCProtocolTests.swift`

**Interfaces:**
- Consumes: `Language`, `Bookmark`, `MeetingID`（計画 01）、`AutomationTrigger`, `AutomationRunRecord`（Task 3・4）
- Produces:
  - `public enum IPCCommand: String, Codable, Sendable, CaseIterable { case start, stop, pause, resume, bookmark, status, list, latest, `import`, regenerate, automationsList = "automations.list", automationsRun = "automations.run" }`（要件書 §16 の表と 1 対 1）
  - `public struct IPCArgs: Codable, Equatable, Sendable { public var lang: Language?; public var note: String?; public var since: String?; public var open: Bool?; public var file: String?; public var meetingID: String?; public var name: String?; public init(lang: Language? = nil, note: String? = nil, since: String? = nil, open: Bool? = nil, file: String? = nil, meetingID: String? = nil, name: String? = nil) }`
  - `public struct IPCRequest: Codable, Equatable, Sendable { public var cmd: IPCCommand; public var args: IPCArgs; public var id: Int }`
  - `public enum IPCErrorCode: String, Codable, Sendable { case notRecording = "not_recording", alreadyRecording = "already_recording", notFound = "not_found", invalidArgs = "invalid_args", unknownCommand = "unknown_command", badRequest = "bad_request", failed }`
  - `public struct IPCError: Codable, Equatable, Sendable, Error { public var code: IPCErrorCode; public var message: String }`
  - `public struct IPCResult: Codable, Equatable, Sendable { public var status: StatusResult?; public var meetings: [MeetingRow]?; public var path: String?; public var meetingID: String?; public var bookmark: Bookmark?; public var automations: [AutomationSummary]?; public var run: AutomationRunRecord? }`
  - `public struct IPCResponse: Codable, Equatable, Sendable { public var id: Int?; public var ok: Bool; public var result: IPCResult?; public var error: IPCError?; public static func success(_ id: Int, _ r: IPCResult) -> IPCResponse; public static func failure(_ id: Int?, _ e: IPCError) -> IPCResponse }`
  - `WireTypes.swift`: `public struct StatusResult: Codable, Equatable, Sendable { public var recorder: RecorderStatusDTO; public var queue: [QueueItemDTO]; public var outputFolderAvailable: Bool }`、`public struct RecorderStatusDTO { state: String /* idle countdown recording paused grace */; meetingID: String?; elapsedSeconds: Int?; device: String?; secondsRemaining: Int?; language: Language? }`、`public struct QueueItemDTO { meetingID: String; stage: String; state: String /* 計画 05 の状態の rawValue。表示と判定は running と awaitingConfirmation だけを見る */; progress: Double?; label: String; message: String? }`、`public enum MeetingRowState: String, Codable, Sendable { case recording, recorded, processing, minutesGenerated = "minutes_generated", transcriptOnly = "transcript_only", failed, tooShort = "too_short" }`、`public struct MeetingRow: Codable, Equatable, Sendable, Identifiable { id: String; title: String; startedAt: Date; durationMinutes: Int?; state: MeetingRowState; progressLabel: String?; filePath: String?; silenceWarning: Bool; summaryFirstLine: String? }`、`public struct AutomationSummary { name: String; on: AutomationTrigger; enabled: Bool; isRunnable: Bool; problem: String? }`（すべて `Codable, Equatable, Sendable` で、`public var` の各項目に既定値（nil・空配列・false）つきの `public init` を持つ）、`public enum StageLabel { public static func text(stage: String, progress: Double?) -> String }`
  - `LineCodec.swift`: `public enum IPCCodec { public static func encode<T: Encodable>(_ v: T) throws -> Data /* 末尾 "\n" 付き 1 行 */; public static func decodeRequest(_ line: Data) throws(IPCDecodeFailure) -> IPCRequest; public static func decodeResponse(_ line: Data) throws -> IPCResponse }`、`public struct IPCDecodeFailure: Error, Equatable { public var id: Int?; public var error: IPCError }`、`public struct LineBuffer: Sendable { public static let maxLineBytes = 1 << 20; public init(); public mutating func append(_ data: Data) throws(IPCError) -> [Data] }`

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func commandsMatchSpecTable() {
    #expect(IPCCommand.allCases.map(\.rawValue) == ["start", "stop", "pause", "resume", "bookmark", "status", "list", "latest", "import", "regenerate", "automations.list", "automations.run"])
}
@Test func decodesSnakeCaseRequest() throws {
    let r = try IPCCodec.decodeRequest(Data(#"{"cmd":"regenerate","args":{"meeting_id":"20261024-1400-a1b2"},"id":7}"#.utf8))
    #expect(r == IPCRequest(cmd: .regenerate, args: IPCArgs(meetingID: "20261024-1400-a1b2"), id: 7))
}
@Test func requestRoundTripForEveryCommand()      // allCases それぞれ、代表的な args で encode → decode が等しい
@Test func encodedLineIsOneLine() throws        // note "一行目\n二行目" の要求 → 末尾だけが 0x0A
@Test func unknownCommandKeepsID() {            // {"cmd":"explode","args":{},"id":4}
    #expect(throws: IPCDecodeFailure(id: 4, error: IPCError(code: .unknownCommand, message: "知らないコマンドです: explode"))) { try IPCCodec.decodeRequest(Data(explode.utf8)) }
}
@Test func malformedLineIsBadRequestWithoutID()   // "not json" → IPCDecodeFailure(id: nil, code .badRequest)
@Test func errorResponseShape() throws {
    let s = String(decoding: try IPCCodec.encode(IPCResponse.failure(3, IPCError(code: .notRecording, message: "録音中ではありません"))), as: UTF8.self)
    #expect(s == #"{"error":{"code":"not_recording","message":"録音中ではありません"},"id":3,"ok":false}"# + "\n")
}
@Test func lineBufferSplitsAcrossChunks()         // "{\"a\"" と ":1}\n{}\n" を順に append → 1 回目 []、2 回目 2 行
@Test func lineBufferRejectsOverlongLine()        // 改行なしで maxLineBytes + 1 → IPCError(code: .badRequest)
@Test func stageLabels()   // ("transcribe", 0.42) → "文字起こし中 42%"、progress nil で summarize → "議事録生成中"、write_vault → "Vault に書き出し中"、update_index → "一覧を更新中"、automations → "Automations 実行中"
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter IPCProtocolTests` → Expected: `cannot find 'IPCCommand' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
エンコーダは `keyEncodingStrategy = .convertToSnakeCase`、`dateEncodingStrategy = .iso8601`、`outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`（overview §3）。nil の項目は出さない。`decodeRequest` は先に `{"id": Int?, "cmd": String}` だけを読み、`cmd` が `IPCCommand` に無ければ `unknownCommand`、JSON でなければ `badRequest`。`StageLabel` の進捗は `Int((progress * 100).rounded(.down))`。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter IPCProtocolTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/IPC Tests/AutoNoteCoreTests/IPC && git commit -m "feat: JSON-lines IPC protocol and wire types"`

---

### Task 7: `SocketServer` と `SocketClient`

**Files:**
- Create: `Sources/AutoNoteCore/IPC/UnixSocket.swift`, `Sources/AutoNoteCore/IPC/SocketServer.swift`, `Sources/AutoNoteCore/IPC/SocketClient.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/SocketTests.swift`

**Interfaces:**
- Consumes: `IPCRequest`, `IPCResponse`, `IPCCodec`, `LineBuffer`, `IPCCommand`, `IPCArgs`（Task 6）、`AppIdentity.bundleID`（Task 2）
- Produces:
  - `public protocol IPCHandler: Sendable { func handle(_ request: IPCRequest) async -> IPCResponse }`
  - `public enum SocketError: Error, Equatable, Sendable { case pathTooLong(bytes: Int), alreadyRunning, system(call: String, errno: Int32) }`
  - `public actor SocketServer { public init(socketURL: URL, handler: any IPCHandler); public func start() throws(SocketError); public func stop() }`
  - `public protocol AppLauncher: Sendable { func launch() throws }`、`public struct OpenBundleLauncher: AppLauncher { public init(bundleID: String = AppIdentity.bundleID) }`
  - `public enum SocketClientError: Error, Equatable, Sendable { case appNotRunning, launchFailed(String), timedOut, protocolError(String) }`
  - `public struct SocketClient: Sendable { public init(socketURL: URL, launcher: (any AppLauncher)?, launchTimeout: Duration = .seconds(10), pollInterval: Duration = .milliseconds(200)); public func send(_ cmd: IPCCommand, args: IPCArgs) async throws(SocketClientError) -> IPCResponse }`

- [ ] **Step 1: 失敗するテストを書く**
ソケットは `/tmp/an-<8hex>/s.sock`。`EchoHandler` は `status` に `IPCResult(path: "echo-\(id)")` を返すテスト内の型。
```swift
@Test func roundTrip() async throws        // start → client.send(.status) → ok、result.path == "echo-1"
@Test func socketFileIs0600() async throws  // start 後の stat の権限 == 0o600
@Test func staleSocketFileIsReplaced()      // 同じパスに通常ファイルを置いておく → start 成功
@Test func secondServerFailsAlreadyRunning()// 1 台目が動いている → 2 台目 start は .alreadyRunning、1 台目は応答し続ける
@Test func pathTooLongIsRejected() async    // フォルダ名 120 文字 → start が .pathTooLong(bytes:) を投げ、bytes >= 104
@Test func concurrentClients() async throws // 5 本並列で send → それぞれ自分の id の応答
@Test func badLineGetsBadRequest()          // 生のソケットで "hello\n" → 応答 1 行、ok false、code bad_request、接続は開いたまま
@Test func clientLaunchesAppWhenSocketMissing() async throws  // FakeLauncher.launch() が 300ms 後にサーバーを start → send 成功、launch 1 回
@Test func clientTimesOutWhenAppNeverAppears() async          // launchTimeout 1 秒、何もしない launcher → .timedOut、経過 < 3 秒
@Test func launcherFailureIsReported() async            // launch() が throw → .launchFailed
@Test func noLauncherFailsFast() async                  // launcher nil、ソケット無し → .appNotRunning
@Test func stopRemovesSocketFile() async throws
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter SocketTests` → Expected: `cannot find 'SocketServer' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
- `UnixSocket.swift`: `sockaddr_un` を組む前に UTF-8 のバイト数を数え、104 以上なら `.pathTooLong`。`socket(AF_UNIX, SOCK_STREAM)`、`bind`、`chmod(0600)`、`listen(16)` の小さなラッパー
- `start()`: パスにファイルがあれば一度 `connect` を試し、つながれば `.alreadyRunning`、つながらなければ `unlink` してから bind（親フォルダは 0700 で作る）。`accept` は専用の `Thread` で回し（ブロッキング）、接続ごとに `Task` を起こして `LineBuffer` で行に分け、1 行ごとに `handler.handle` の応答を 1 行で返す。解読失敗は `IPCResponse.failure(failure.id, failure.error)` を返して接続は保つ
- `SocketClient.send`: `connect` が `ENOENT` か `ECONNREFUSED` なら、launcher が nil なら `.appNotRunning`、あれば `launch()` してから `pollInterval` ごとに `connect` を試し、`launchTimeout` を過ぎたら `.timedOut`。要求の `id` は 1 から振る。応答待ちにも `launchTimeout` と同じ上限をかける
- `OpenBundleLauncher.launch()`: `/usr/bin/open -g -b <bundleID>` を `Process` で実行し、終了コードが 0 以外なら stderr を入れて throw（`-g` で前面に出さない）
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter SocketTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/IPC Tests/AutoNoteCoreTests/IPC && git commit -m "feat: unix socket server and client with app auto-launch"`

---

### Task 8: サービスの窓口（Port）、アダプタ、会議一覧の組み立て

画面と CLI が計画 01〜05 の具体型に直接触らないよう、窓口を protocol で切る。フェイクで AppModel と CommandRouter をテストできるようにする。

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/Ports.swift`, `LiveAdapters.swift`, `OutputFolderServices.swift`, `MeetingListBuilder.swift`
- Create: `Sources/AutoNoteTestSupport/FakePorts.swift`
- Modify: `Sources/AutoNoteCore/Automations/AutomationDispatcher.swift`（`runOne` を足す）
- Test: `Tests/AutoNoteCoreTests/Presentation/MeetingListBuilderTests.swift`, `RecorderCommandRulesTests.swift`, `MeetingsAdapterTests.swift`

**Interfaces:**
- Consumes: 冒頭の表の 01〜05 の行、`MeetingRow`, `MeetingRowState`, `QueueItemDTO`, `StageLabel`, `AutomationSummary`（Task 6）、`AutomationDispatcher`, `AutomationRunner`, `AutomationContextBuilder`（Task 4・5）
- Produces:
  - `public enum AppCommandError: Error, Equatable, Sendable { case notRecording, alreadyRecording, notFound(String), invalid(String), failed(String) }`
  - `public enum RecorderCommand: Sendable { case start, stop, pause, resume, bookmark }`、`public enum RecorderCommandRules { public static func check(_ c: RecorderCommand, state: RecorderState) throws(AppCommandError) }`
  - `public protocol RecorderPort: Sendable { func current() async -> RecorderSnapshot; func snapshots() async -> AsyncStream<RecorderSnapshot>; func start(language: Language?) async throws; func stop() async throws; func pause() async throws; func resume() async throws; func bookmark(note: String?) async throws -> Bookmark; func cancelCountdown() async; func setLanguage(_ l: Language) async; func handleNotice(_ action: UserNoticeAction) async }`
  - `public protocol RecordingEventsPort: Sendable { func events() async -> AsyncStream<RecordingEvent> }`
  - `public struct QueueStatus: Equatable, Sendable { public var items: [QueueItemDTO]; public var pausedForRecording: Bool; public static let empty: QueueStatus }`、`public protocol QueuePort: Sendable { func status() async -> QueueStatus; func updates() async -> AsyncStream<QueueStatus>; func regenerate(_ id: MeetingID) async throws; func resolveOverwrite(_ id: MeetingID, overwrite: Bool) async throws; func acceptShortRecording(_ id: MeetingID) async throws; func delete(_ id: MeetingID) async throws }`
  - `public enum SaveMinutesOutcome: Equatable, Sendable { case saved(URL), externallyEdited(URL) }`、`public protocol MeetingsPort: Sendable { func rows() async throws -> [MeetingRow]; func latestMinutesFile() async throws -> URL?; func manifest(_ id: MeetingID) async throws -> Manifest; func minutes(_ id: MeetingID) async throws -> MinutesOutput?; func transcript(_ id: MeetingID, kind: TranscriptKind) async throws -> Transcript?; func saveMinutes(_ id: MeetingID, _ m: MinutesOutput, renameFile: Bool, overwrite: Bool) async throws -> SaveMinutesOutcome; func importAudio(_ file: URL, startedAt: Date?) async throws -> MeetingID; func recover(_ id: MeetingID) async throws; func discard(_ id: MeetingID) async throws }`（`TranscriptKind` は計画 01 のもの。本計画は定義しない）
  - `public protocol AutomationsPort: Sendable { func summaries() async -> ([AutomationSummary], warnings: [String]); func run(name: String, meetingID: MeetingID) async throws -> AutomationRunRecord; func recentRuns(limit: Int) async -> [AutomationRunRecord]; func records() async -> AsyncStream<AutomationRunRecord> }`
  - `public protocol LiveTranscriptPort: Sendable { func updates() async -> AsyncStream<[Utterance]> }`（実装は Task 13 の `LiveTranscriptionWiring`）、`public protocol OutputFolderPort: Sendable { func isAvailable() async -> Bool }`、`public protocol FileOpener: Sendable { func open(_ file: URL) async }`
  - `public struct AppPorts: Sendable { recorder, events, queue, meetings, automations, live, outputFolder, opener; public init(…) }`（各 `any …Port`）
  - `public actor OutputFolderServices { public init(paths: AppPaths); public func rebuild(outputFolder: String?) async throws -> PortableSyncReport; public func portable() -> PortableConfigStore; public func vault() -> (folder: URL, writer: VaultWriter)? }`（`rebuild` は `PortableConfigStore(paths:outputFolder:)` を作って `sync()` し、フォルダがあれば `VaultWriter(outputFolder:paths:)` も作り直す）、`public actor QueueHolder { public init(_ q: PostProcessingQueue); public var queue: PostProcessingQueue { get }; public func replace(_ q: PostProcessingQueue) }`
  - `public enum MeetingListBuilder { public static func build(index: [IndexEntry], manifests: [Manifest], queue: QueueStatus, outputFolder: URL?) -> [MeetingRow]; public static func filter(_ rows: [MeetingRow], since: String, calendar: Calendar) throws(AppCommandError) -> [MeetingRow] }`
  - アダプタ: `CoordinatorRecorderPort(coordinator: AutoRecordCoordinator)`、`SessionEventsPort(session: RecordingSession)`、`QueueAdapter(holder: QueueHolder)`、`MeetingsAdapter(paths:manifests:settings:output:importer:crashRecovery:route:appVersion:)`（`route: @Sendable (Manifest) async -> Void` は Task 13 の `AppWiring.route`）、`AutomationsAdapter(file:dispatcher:runner:manifests:paths:output:)`、`PortableOutputFolderPort(output:)`
  - フェイク（`FakePorts.swift`）: `FakeRecorderPort`・`FakeRecordingEventsPort`・`FakeQueuePort`・`FakeMeetingsPort`・`FakeAutomationsPort`・`FakeLiveTranscriptPort`・`FakeOutputFolderPort`・`FakeFileOpener`。それぞれ actor で、呼ばれた操作を `calls: [String]` に積み、流す値は `send(_:)` で入れ、`nextError: AppCommandError?` を一度だけ投げる（`FakeFileOpener` は `opened: [URL]` も持つ）。`struct FakePorts { var ports: AppPorts }` でまとめて作る

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test(arguments: [(RecorderCommand.bookmark, RecorderState.idle), (.bookmark, .countdown), (.stop, .idle), (.stop, .countdown), (.pause, .idle), (.resume, .idle)])
func rejectsWhenNotRecording(c: RecorderCommand, s: RecorderState) { #expect(throws: AppCommandError.notRecording) { try RecorderCommandRules.check(c, state: s) } }
@Test(arguments: [RecorderState.recording, .paused, .grace]) func startWhileRecordingIsAlready(s: RecorderState) { #expect(throws: AppCommandError.alreadyRecording) { try RecorderCommandRules.check(.start, state: s) } }
@Test func pauseResumeWrongState() {   // .pause・.paused → .invalid("すでに一時停止中です")、.resume・.recording → .invalid("一時停止中ではありません")、.pause・.grace → .invalid("機材が外れているあいだは一時停止できません")
}
@Test func startFromCountdownIsAllowed() throws { try RecorderCommandRules.check(.start, state: .countdown) }  // §5.9 手動開始でカウントダウン破棄
@Test func indexOnlyEntryAppears()        // manifest が消えた会議（IndexEntry だけ）→ state .minutesGenerated、filePath == "<folder>/<linkPath>.md"
@Test func manifestOnlyRecordingAppears() // Vault に無い録音中 → state .recording、title "（無題）"
@Test func indexTitleWins()               // 両方ある → IndexEntry.title
@Test func runningJobOverridesState()     // QueueStatus に running の transcribe 0.42 → state .processing、progressLabel "文字起こし中 42%"
@Test func indexStatusMapping()           // status "transcript_only" → .transcriptOnly、"failed" → .failed、それ以外 → .minutesGenerated
@Test func tooShortAndSilenceWarning()    // manifest .tooShort → .tooShort、silenceWarning を引き継ぐ
@Test func newestFirstAndSinceFilter() throws  // "2026-10-01" より前は落ちる。"10/01" → .invalid("日付は YYYY-MM-DD で指定してください: 10/01")
// MeetingsAdapterTests（一時の AppPaths・出力フォルダ。フィクスチャ 20261024-1400-a1b2 の manifest と final.json を置く）
@Test func saveMinutesWritesJSONThenVault() async throws   // .saved(url)。minutes.json と manifest.title が新しいタイトル、Vault ファイルと _index.md がある
@Test func externalEditIsReportedThenForced() async throws // 保存 → Vault ファイルを外で書き換え → 2 回目は .externallyEdited(url)（Vault は外の内容のまま、minutes.json は新しい）→ overwrite: true で .saved
@Test func saveWithoutOutputFolderFails() async            // フォルダなし → .failed("出力フォルダが見つかりません")
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter "MeetingListBuilderTests|RecorderCommandRulesTests|MeetingsAdapterTests"` → Expected: `cannot find 'MeetingListBuilder' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
- `RecorderCommandRules`: start は `recording/paused/grace` で `.alreadyRecording`。stop は `idle/countdown` で `.notRecording`。pause は `recording` だけ、resume は `paused` だけ（`idle/countdown` は `.notRecording`、他はテストの `.invalid` 文言）。bookmark は `recording/paused/grace`
- アダプタは操作の前に `RecorderCommandRules.check(_, state: coordinator.current().state)` を呼ぶ。`bookmark` は `coordinator.bookmark(note:)`、`AutoRecordError.notRecording` は `.notRecording` に、他の計画のエラーは `.failed(error.localizedDescription)` に包む
- `QueueAdapter`: `holder.queue` の `snapshot()`・`snapshots()` を `QueueStatus` に写す（`JobProgress` 1 件 → `QueueItemDTO(meetingID, stage, state: 状態の rawValue, progress, label: StageLabel.text(stage:progress:), message: lastError)`）。出力先の変更で待ち行列が作り直されても `holder` から引くので古いものを掴まない
- `MeetingsAdapter.saveMinutes`（overview の順）: `minutes.json`（`paths.minutesFile(id)`）を原子的に書く → `manifests.update(id) { $0.title = m.title }` → `MeetingDocument(manifest:, transcript: final.json, minutes: m, frontmatter: FrontmatterTemplate(text: portable.read(.frontmatter) ?? defaultText), appVersion:, timeZone: .current)` → `writer.write(doc, policy: overwrite ? .force : .ifUnchanged, renameToMatchTitle: renameFile)`。`.conflict(url)` は外部編集なので `.externallyEdited(url)`、`.written(url)` は `rebuildIndex()` してから `.saved(url)`。上書きを断った場合 `minutes.json` は新しいまま残り、Vault は変えない（次の保存か再生成で揃う）
- `MeetingsAdapter` のほか: `rows()` は `output.vault()` があれば `VaultScanner.scan` を読み、無ければ manifest だけで組む。`latestMinutesFile()` は `filePath` のある最新の行。`minutes`・`transcript` は `paths.minutesFile` / `paths.transcriptFile(id, kind)` を読み、無ければ nil。`importAudio` は `importer.importFile(file, startedAt:, language: settings.defaultLanguage)` の manifest を `route` に渡す。`recover` は `crashRecovery.recover(id)` の manifest を `route` に渡す（Task 13 で enqueue か短すぎる通知）。`discard` は `crashRecovery.discard(id)`
- `AutomationDispatcher.runOne(name:context:) async throws -> AutomationRunRecord` を足す（`isRunnable` でなければ `.invalid(problem ?? "無効になっています")`、無ければ `.notFound("Automation が見つかりません: <name>")`。`dedupeKey` は nil＝手動）。`AutomationsAdapter.run` は manifest、`minutes.json` の有無、`writer.record(for:)` から `AutomationContextBuilder.make(event: 定義の on, …)` を作って `runOne` を呼ぶ
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter "MeetingListBuilderTests|RecorderCommandRulesTests|MeetingsAdapterTests" && swift build` → Expected: PASS、ビルド成功（アダプタが計画 01〜05 の型と合う）
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation Sources/AutoNoteCore/Automations Sources/AutoNoteTestSupport Tests/AutoNoteCoreTests/Presentation && git commit -m "feat: service ports, adapters and meeting list builder"`

---

### Task 9: `CommandRouter`（ソケットの要求をサービスへ）

**Files:**
- Create: `Sources/AutoNoteCore/IPC/CommandRouter.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/CommandRouterTests.swift`

**Interfaces:**
- Consumes: `IPCHandler`（Task 7）、`IPCRequest/IPCResponse/IPCResult/StatusResult/...`（Task 6）、`AppPorts`, `AppCommandError`, `MeetingListBuilder.filter`, `FakePorts`（Task 8）
- Produces: `public struct CommandRouter: IPCHandler { public init(ports: AppPorts, now: @Sendable @escaping () -> Date = { Date() }, calendar: Calendar = .current) }`、`public static func ipcError(_ e: Error) -> IPCError`

エラー文言（本計画で固定。CLI と画面で同じものを出す）:

| `AppCommandError` | `IPCErrorCode` | message |
|---|---|---|
| `.notRecording` | `not_recording` | 録音中ではありません |
| `.alreadyRecording` | `already_recording` | すでに録音中です |
| `.notFound(m)` | `not_found` | m |
| `.invalid(m)` | `invalid_args` | m |
| `.failed(m)` / その他 | `failed` | m |

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func statusIdle() async {
    let r = await CommandRouter(ports: fakes.ports).handle(IPCRequest(cmd: .status, args: IPCArgs(), id: 1))
    #expect(r.ok && r.result?.status?.recorder.state == "idle" && r.result?.status?.queue == [])
}
@Test func statusRecordingElapsed()         // startedAt = now - 754 → elapsedSeconds 754、device "Jabra"
@Test func statusCountdownRemaining()       // countdown、deadline = now + 3 → secondsRemaining 3
@Test func bookmarkWhileIdle() async {
    let r = await router.handle(IPCRequest(cmd: .bookmark, args: IPCArgs(note: "x"), id: 2))
    #expect(!r.ok && r.error == IPCError(code: .notRecording, message: "録音中ではありません"))
}
@Test func startPassesLanguage()            // args.lang .en → FakeRecorderPort.calls == ["start(en)"]
@Test func listSinceAndInvalidSince()       // since "2026-10-01" で絞る、"10/01" → invalid_args
@Test func latestNone()                     // → not_found "議事録がまだありません"
@Test func latestOpenCallsOpener()          // open true → FakeFileOpener.opened == [path]
@Test func importNeedsAbsoluteExistingFile()// "rec.m4a" → invalid_args "ファイルは絶対パスで渡してください"、存在しない絶対パス → not_found "ファイルがありません: <path>"
@Test func regenerateUnknown()              // FakeQueuePort.nextError .notFound("会議が見つかりません: x") → not_found
@Test func automationsListAndRun()          // list → automations 2 件、run name 無し → invalid_args "Automation の名前と会議 ID が要ります"
@Test func unexpectedErrorIsFailed()        // Port が任意の Error → code failed
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter CommandRouterTests` → Expected: `cannot find 'CommandRouter' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
`handle` は `cmd` で分岐し、各 Port を呼んで `IPCResult` の該当項目だけを埋める。`status` は `recorder.current()`・`queue.status().items`・`outputFolder.isAvailable()` から組み、`QueueItemDTO.label` は `StageLabel.text`。`regenerate` と `automations.run` の `meetingID` は `MeetingID(rawValue:)` で包む。`import` の `startedAt` は nil（ファイルの作成日時が既定。§10）。MainActor には乗らない。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter CommandRouterTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/IPC/CommandRouter.swift Tests/AutoNoteCoreTests/IPC/CommandRouterTests.swift && git commit -m "feat: route IPC commands to app services"`

---

### Task 10: CLI `autonote`（§16 の全コマンド、`--json`、終了コード、使い方）

**Files:**
- Create: `Sources/AutoNoteCore/IPC/CLIInvocation.swift`, `Sources/AutoNoteCore/IPC/CLIRenderer.swift`
- Modify: `Sources/autonote/main.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/CLITests.swift`

**Interfaces:**
- Consumes: `IPCCommand`, `IPCArgs`, `IPCResponse`（Task 6）、`SocketClient`, `SocketClientError`, `OpenBundleLauncher`（Task 7）、`AppIdentity`（Task 2）
- Produces:
  - `public struct CLIInvocation: Equatable, Sendable { public var command: IPCCommand; public var args: IPCArgs; public var json: Bool }`
  - `public enum CLIParseResult: Equatable, Sendable { case invocation(CLIInvocation), version, help, dev([String]) }`
  - `public struct CLIUsageError: Error, Equatable { public var message: String }`
  - `public enum CLIParser { public static func parse(_ argv: [String], cwd: URL) throws(CLIUsageError) -> CLIParseResult }`
  - `public struct CLIOutput: Equatable, Sendable { public var stdout: String; public var stderr: String; public var exitCode: Int32 }`
  - `public enum CLIRenderer { public static let usage: String; public static func render(_ r: IPCResponse, for inv: CLIInvocation, timeZone: TimeZone = .current) -> CLIOutput; public static func render(_ e: SocketClientError, json: Bool) -> CLIOutput; public static func render(_ e: CLIUsageError) -> CLIOutput }`

使い方（`CLIRenderer.usage`。`dev` は出さない。各行は `usage:` の後に揃える）:
```
usage: autonote start [--lang auto|ja|en]
       autonote stop | pause | resume
       autonote bookmark [メモ]
       autonote status [--json]
       autonote list [--since YYYY-MM-DD] [--json]
       autonote latest [--open] [--json]
       autonote import <file>
       autonote regenerate <id>
       autonote automations list [--json]
       autonote automations run <名前> <id>
       autonote --version
```

- [ ] **Step 1: 失敗するテストを書く**
```swift
let cwd = URL(filePath: "/Users/x/work")
@Test func parsesEveryCommand() throws {
    #expect(try CLIParser.parse(["start", "--lang", "en"], cwd: cwd) == .invocation(.init(command: .start, args: IPCArgs(lang: .en), json: false)))
    #expect(try CLIParser.parse(["bookmark", "大事", "な点"], cwd: cwd) == .invocation(.init(command: .bookmark, args: IPCArgs(note: "大事 な点"), json: false)))
    #expect(try CLIParser.parse(["list", "--json", "--since", "2026-10-01"], cwd: cwd) == .invocation(.init(command: .list, args: IPCArgs(since: "2026-10-01"), json: true)))
    #expect(try CLIParser.parse(["import", "録音 1.m4a"], cwd: cwd) == .invocation(.init(command: .import, args: IPCArgs(file: "/Users/x/work/録音 1.m4a"), json: false)))
    #expect(try CLIParser.parse(["automations", "run", "Slack に要約を投稿", "20261024-1400-a1b2"], cwd: cwd) == .invocation(.init(command: .automationsRun, args: IPCArgs(meetingID: "20261024-1400-a1b2", name: "Slack に要約を投稿"), json: false)))
    // stop, pause, resume, status, latest --open, regenerate <id>, automations list も同様に 1 行ずつ
}
@Test func versionAndDev() throws   // ["--version"] → .version、["dev", "render-fixture", "--out", "/tmp/o"] → .dev(["render-fixture", "--out", "/tmp/o"])
@Test(arguments: [[], ["start", "--lang", "fr"], ["regenerate"], ["automations", "run", "x"], ["frobnicate"], ["stop", "extra"]])
func usageErrors(argv: [String]) { #expect(throws: CLIUsageError.self) { try CLIParser.parse(argv, cwd: cwd) } }
@Test func usageErrorExitCode()     // CLIUsageError("知らないコマンドです: frobnicate") → exitCode 1、stderr が "エラー: 知らないコマンドです: frobnicate\n" で始まり "usage: autonote start" を含む
@Test func statusHumanAndJSON() throws {
    let r = IPCResponse.success(1, IPCResult(status: StatusResult(recorder: .init(state: "idle"), queue: [], outputFolderAvailable: true)))
    #expect(CLIRenderer.render(r, for: inv(.status)).stdout == "録音器: 待機\n待ち行列: なし\n")
    let j = CLIRenderer.render(r, for: inv(.status, json: true))
    #expect(j.exitCode == 0 && j.stdout.contains(#""state":"idle""#))
}
@Test func statusRecordingHuman()   // recording 754 秒 device "Jabra" → "録音器: 録音中 00:12:34（Jabra）"。queue 1 件 → "  20261024-1400-a1b2  文字起こし中 42%"。出力フォルダなし → 最後に "出力フォルダが見つかりません"
@Test func errorResponse() {
    let e = IPCResponse.failure(2, IPCError(code: .notRecording, message: "録音中ではありません"))
    #expect(CLIRenderer.render(e, for: inv(.bookmark)) == CLIOutput(stdout: "", stderr: "エラー: 録音中ではありません\n", exitCode: 1))
    #expect(CLIRenderer.render(e, for: inv(.bookmark, json: true)) == CLIOutput(stdout: #"{"error":{"code":"not_recording","message":"録音中ではありません"}}"# + "\n", stderr: "", exitCode: 1))
}
@Test func clientErrors()   // .timedOut → stderr "エラー: AutoNote が 10 秒以内に応答しませんでした\n"、.appNotRunning → "エラー: AutoNote が起動していません\n"、.launchFailed(m) → "エラー: AutoNote を起動できませんでした: m\n"。いずれも exitCode 1
@Test func listHuman()   // "2026-10-24 14:00  62 分  プロジェクト定例  完了  20261024-1400-a1b2"。状態の表示: recording 録音中 / processing progressLabel / minutes_generated 完了 / transcript_only 議事録 未生成 / failed 失敗 / too_short 短すぎる録音 / recorded 録音済み
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter CLITests` → Expected: `cannot find 'CLIParser' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
- `CLIParser`: `--json` はどの位置でも取り除いてから解釈する。引数の数が合わない・知らないオプションは `CLIUsageError`。`--since` の書式はアプリ側（Task 9）で検める。`import` は `cwd` に対して絶対パスにし `standardizedFileURL` で正規化
- `CLIRenderer`: 人向けは上のテストの書式。`latest` は `path` だけ。`import`・`regenerate` は「受け付けました: <id>」。`automations list` は「<name>  <on>  有効|無効（problem）」。`automations run` は「終了コード <n>（<秒> 秒）ログ: <logDirectory>」、タイムアウトは「タイムアウトしました（<秒> 秒）ログ: …」で終了コード 1。`--json` の成功は `result` だけを 1 行で出す
- `main.swift`: `--version` は今のまま。`dev` は計画 01〜05 が足した分岐へそのまま渡す（消さない）。それ以外は `CLIParser` → `SocketClient(socketURL: AppPaths.resolve().socketFile, launcher: AppIdentity.isDataDirectoryOverridden(env) ? nil : OpenBundleLauncher())` → `CLIRenderer` → stdout/stderr に書いて `exit(exitCode)`。引数なしは使い方を stderr に出して終了コード 1（E2E 項目 6 が `usage:` と 1 を見る）
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter CLITests && swift build --product autonote && $(swift build --show-bin-path)/autonote; echo "exit=$?"` → Expected: テスト PASS。最後のコマンドは stderr に `usage: autonote start …` を出し `exit=1`
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/IPC Sources/autonote/main.swift Tests/AutoNoteCoreTests/IPC/CLITests.swift && git commit -m "feat: autonote user commands over the socket"`

---

### Task 11: 表示規則と `AppModel`（メニューバー、リアルタイム表示、終了判定、Obsidian リンク、ショートカット、状態の集約）

画面から切り離せる判断を純粋な関数・値型にし、各サービスの状態を `AppModel` に集めてテストする。

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/MenuBarPresentation.swift`, `LiveTranscriptBuffer.swift`, `QuitPolicy.swift`, `ObsidianLink.swift`, `KeyCombo.swift`, `AppModel.swift`
- Test: `Tests/AutoNoteCoreTests/Presentation/{MenuBarPresentation,LiveTranscriptBuffer,QuitPolicy,ObsidianLink,KeyCombo,AppModel}Tests.swift`

**Interfaces:**
- Consumes: `RecorderSnapshot`, `RecorderState`, `UserNotice`, `UserNoticeAction`（計画 03）、`LiveFeed.isMarker(_:)`（計画 04）、`Utterance`, `TimelineTime`, `Shortcuts`（計画 01）、`RecordingEvent`, `StopReason`（計画 02）、`AppPorts`, `QueueStatus`, `AppCommandError`, フェイク（Task 8）、`MeetingRow`, `StageLabel`, `AutomationRunRecord`（Task 4・6）、`CommandRouter.ipcError`（Task 9。文言を揃える）
- Produces:
  - `public enum MenuItem: Equatable, Sendable { case status(String), startRecording, stop, pause, resume, bookmark, cancelCountdown, language(current: Language), openWindow, openLatestMinutes(enabled: Bool), minutesMissing(MeetingID, label: String), automationFailed(name: String, meetingID: MeetingID), settings, quit }`
  - `public struct MenuBarPresentation: Equatable, Sendable { public var symbol: String; public var title: String?; public var items: [MenuItem]; public static func make(recorder: RecorderSnapshot, queue: QueueStatus, outputFolderAvailable: Bool, latestMinutesAvailable: Bool, rows: [MeetingRow], automationFailures: [AutomationRunRecord], now: Date) -> MenuBarPresentation }`
  - `public enum LiveLine: Equatable, Sendable { case utterance(Utterance), marker(Utterance) }`、`public struct LiveTranscriptBuffer: Equatable, Sendable { public init(); public mutating func update(_ snapshot: [Utterance]); public mutating func reset(); public var lines: [LiveLine] { get } }`（`LiveFeed` が並べ・置換・印を済ませた全体を受けるだけ。印は `LiveFeed.isMarker` で見分ける）
  - `public enum QuitReason: Sendable { case user, powerOff }`、`public enum QuitDecision: Equatable, Sendable { case terminateNow, cancelCountdownThenTerminate, confirm, stopThenTerminate }`、`public enum QuitPolicy { public static let confirmMessage = "録音中です。停止して終了しますか？"; public static func decide(_ s: RecorderState, reason: QuitReason) -> QuitDecision }`
  - `public enum ObsidianLink { public static func url(for file: URL) -> URL }`
  - `public struct KeyCombo: Equatable, Hashable, Sendable, CustomStringConvertible { public var keyCode: UInt32; public var modifiers: UInt32 /* Carbon: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096 */; public init(keyCode: UInt32, modifiers: UInt32); public init?(parsing: String); public var description: String /* 保存形 "ctrl+option+b" */; public var display: String /* "⌃⌥B" */; public func validate() throws(AppCommandError) }`
  - `public enum ShortcutAction: String, Sendable, CaseIterable { case bookmark, toggleRecording, togglePause; public var keyPath: WritableKeyPath<Shortcuts, String> }`、`public struct ShortcutBindings: Equatable, Sendable { public init(_ s: Shortcuts); public func combo(for: ShortcutAction) -> KeyCombo?; public func duplicates() -> [ShortcutAction] }`（表示と登録のための読み取り専用。保存は `Shortcuts` の文字列）
  - `public enum UserAction: Equatable, Sendable { case start, stop, pause, resume, bookmark(String?), cancelCountdown, setLanguage(Language), regenerate(MeetingID), delete(MeetingID), rerunAutomation(name: String, meetingID: MeetingID), importAudio(URL, startedAt: Date?), openLatestMinutes, open(MeetingID), notice(UserNoticeAction), toggleRecording, togglePause }`
  - `@MainActor @Observable public final class AppModel { public init(ports: AppPorts, now: @escaping @Sendable () -> Date = { Date() }); public private(set) var recorder: RecorderSnapshot; public private(set) var queue: QueueStatus; public private(set) var meetings: [MeetingRow]; public private(set) var live: LiveTranscriptBuffer; public private(set) var outputFolderAvailable: Bool; public private(set) var automationFailures: [AutomationRunRecord]; public private(set) var prompts: [UserNotice]; public private(set) var diskWarning: String?; public private(set) var lastError: String?; public var selectedMeetingID: MeetingID?; public func run() async; public func refresh() async; public func menuBar(now: Date) -> MenuBarPresentation; public func perform(_ a: UserAction) async; public func noticePosted(_ n: UserNotice); public func noticeWithdrawn(id: String); public func quitDecision(reason: QuitReason) -> QuitDecision }`

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func idle() {
    let p = make(state: .idle)
    #expect(p.symbol == "waveform" && p.title == nil)     // 計画 00 の E2E 7b はアイドル時の項目名 waveform を見る
    #expect(p.items.contains(.startRecording) && !p.items.contains(.stop) && !p.items.contains(.cancelCountdown) && p.items.suffix(2) == [.settings, .quit])
}
@Test func countdown()            // deadline now+3、deviceName "Jabra" → .status("Jabraが接続されました。3 秒後に録音を始めます")、.cancelCountdown と .startRecording あり
@Test func recording()            // startedAt now-754 → symbol "record.circle"、title "12:34"、.stop .pause .bookmark .language(current: .ja)。3754 秒 → "1:02:34"
@Test func paused()               // symbol "pause.circle"、.resume あり、.pause なし、status "一時停止中"
@Test func graceHasNoCancel() {   // 要件書 §5.9・§15.1（Task 1）
    let p = make(state: .grace, startedAt: now - 100, deadline: now + 12)
    #expect(p.items.contains(.status("機材が外れました。12 秒後に停止")) && !p.items.contains(.cancelCountdown) && p.items.contains(.stop))
}
@Test func processingAndFolderAndFailures() // idle + running transcribe 0.42 → symbol "hourglass"、.status("文字起こし中 42%")。フォルダなし → .status("出力フォルダが見つかりません")。transcript_only の行 → .minutesMissing(id, label: "議事録 未生成: 10/24 14:00")、失敗記録 → .automationFailed
@Test func liveLinesFromFeedSnapshot()  // [u(10, 自分), 印(20, "── ブックマーク ──"), u(30, 相手, isFinal false)] → [.utterance, .marker, .utterance]。update のたびに全体を置き換える。reset で空
@Test func quitDecisions() {
    #expect(QuitPolicy.decide(.idle, reason: .user) == .terminateNow && QuitPolicy.decide(.countdown, reason: .user) == .cancelCountdownThenTerminate)
    for s in [RecorderState.recording, .paused, .grace] { #expect(QuitPolicy.decide(s, reason: .user) == .confirm && QuitPolicy.decide(s, reason: .powerOff) == .stopThenTerminate) }
}
@Test func obsidianLinkEncodesEverythingButUnreserved() {
    let u = ObsidianLink.url(for: URL(filePath: "/Users/a/Vault/Meetings/2026/2026-10-24_1400_定例 #1 & A.md"))
    #expect(u.absoluteString == "obsidian://open?path=%2FUsers%2Fa%2FVault%2FMeetings%2F2026%2F2026-10-24_1400_%E5%AE%9A%E4%BE%8B%20%231%20%26%20A.md")
}
@Test func parsesSettingsStrings() {
    #expect(KeyCombo(parsing: "ctrl+option+b") == KeyCombo(keyCode: 11, modifiers: 6144) && KeyCombo(parsing: "ctrl+option+b")?.display == "⌃⌥B")
    #expect(KeyCombo(parsing: "cmd+shift+option+ctrl+a")?.description == "ctrl+option+shift+cmd+a")   // 保存形は ctrl option shift cmd の順
    #expect(KeyCombo(parsing: "ctrl+option") == nil && KeyCombo(parsing: "hyper+b") == nil && KeyCombo(parsing: "") == nil)
}
@Test func defaultShortcuts()     // ShortcutBindings(Shortcuts()) → ⌃⌥B / ⌃⌥R（keyCode 15）/ ⌃⌥P（keyCode 35）、duplicates() == []
@Test func validateAndDuplicates() // modifiers 0 や shiftKey だけ → throws .invalid("⌃ ⌥ ⌘ のどれかを含めてください")。bookmark と togglePause が同じ文字列 → [.bookmark, .togglePause]
// AppModelTests（@MainActor。run() を Task で起こし、フェイクに流してから internal な settle() で待つ）
@Test func recorderSnapshotDrivesMenuBar() async  // recording の snapshot → menuBar(now:).symbol == "record.circle"
@Test func liveUpdatesAndResetOnNewMeeting() async // FakeLiveTranscriptPort が [Utterance] を 2 回流す → live.lines は後の方。meetingID が変わったら空
@Test func queueChangeRefreshesMeetings() async   // QueueStatus が変わるたび FakeMeetingsPort の rows 呼び出しが増える
@Test func actionsForwarded() async               // .bookmark("x") → calls == ["bookmark(x)"]。.toggleRecording は idle → start、recording → stop。.togglePause は recording → pause、paused → resume
@Test func errorsSurfaceWithRouterWording() async // nextError .notRecording → lastError == "録音中ではありません"
@Test func automationFailureCollectedAndCleared() async // 失敗記録 → 1 件。同名・同会議の成功で消える
@Test func diskWarnings() async   // .diskSpaceLow(availableBytes:) → "ディスクの空きが 1GB を切りました"、.stopped(m, .diskFull) → "ディスクの空きが 500MB を切ったため録音を停止しました"
@Test func noticeActionsRouted() async  // .notice(.cancelCountdown)・.startNow・.registerDevice → recorder.handleNotice。.retry(id) → queue.regenerate(id)。.resolveOverwrite(id, true) → queue.resolveOverwrite。.transcribeTooShort → queue.acceptShortRecording、.discardTooShort → queue.delete。.recoverInterrupted → meetings.recover、.discardInterrupted → meetings.discard。.openMeeting(id) → selectedMeetingID == id
@Test func promptsKeptUntilAnswered() async      // noticePosted(.recordingTooShort(id)) → prompts 1 件。.notice(.discardTooShort(id)) か noticeWithdrawn(id:) で消える。.minutesGenerated は prompts に入れない
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter "MenuBarPresentationTests|LiveTranscriptBufferTests|QuitPolicyTests|ObsidianLinkTests|KeyComboTests|AppModelTests"` → Expected: `cannot find 'MenuBarPresentation' in scope` などでビルド失敗
- [ ] **Step 3: 実装する**
- `MenuBarPresentation.make` の並び: 状態行（あれば）→ 録音操作（idle/countdown: 録音開始、recording: 停止・一時停止・ブックマーク、paused: 停止・再開・ブックマーク、grace: 停止・ブックマーク）→ countdown のときだけ取り消す（`recorder.canCancelCountdown`）→ 録音中なら言語 → 待ち行列の状態行（running の各件 `label`）→ 出力フォルダなし → 議事録 未生成・Automation 失敗の各件 → ウィンドウを開く → 最新の議事録を開く → 設定 → 終了。記号は idle かつ running があれば `hourglass`、idle/countdown は `waveform`、recording/grace は `record.circle`、paused は `pause.circle`。`title` は recording/paused/grace だけ（経過時間。一時停止中も進む §5.4）。残り秒は `ceil(deadline - now)`、0 未満は 0
- `ObsidianLink`: `path` の値は ASCII の英数字と `-._~` だけを残して百分率符号化する（`CharacterSet.alphanumerics` は漢字も含むので使わない）
- `KeyCombo(parsing:)`: `+` で分けて小文字にし、`ctrl` `option` `shift` `cmd` と、最後に 1 つのキー（a〜z、0〜9、f1〜f12。ANSI の keyCode 表）。キーが無い・2 つ以上・知らない語は nil。`display` は ⌃⌥⇧⌘ の順＋大文字のキー。読めない設定値は登録せず、設定画面に「読めないショートカット: <文字列>」と出す
- `AppModel.run()`: `withTaskGroup` で recorder・events・queue・live・automations の各ストリームを購読し、30 秒ごとに `outputFolder.isAvailable()` と `meetings.rows()` を読み直す［私の判断］。`perform` の失敗は `CommandRouter.ipcError(e).message` を `lastError` に。`prompts` に入れるのは `recordingTooShort`・`interruptedRecordingFound`・`overwriteConfirmation` だけ（ウィンドウの帯に出す要確認の通知）。`.openPrivacySettings` は App 側が開くので model は何もしない
- [ ] **Step 4: 通過を確かめる** — Run: Step 2 と同じ → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation Tests/AutoNoteCoreTests/Presentation && git commit -m "feat: presentation rules, shortcut parsing and AppModel"`

---

### Task 12: 通知（`UserNotifier` の実装）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/NoticeContent.swift`, `Sources/AutoNoteCore/Presentation/NoticeRelay.swift`
- Create: `Sources/AutoNoteApp/SystemUserNotifier.swift`
- Modify: `Resources/Info.plist`（`NSUserNotificationAlertStyle` = `alert` を足す）
- Test: `Tests/AutoNoteCoreTests/Presentation/NoticeContentTests.swift`

**Interfaces:**
- Consumes: `UserNotifier`, `UserNotice`（`id`）、`UserNoticeAction`, `RegisterAnswer`, `DeviceNoticeCopy`（計画 03。case は overview §3 の字面）、`RecordingEvent`, `SilenceMonitor.micMessage` / `systemMessage`（計画 02）、`QueueStatus`（Task 8）
- Produces:
  - `public struct NoticeButton: Equatable, Sendable { public var id: String; public var title: String }`
  - `public struct NoticeContent: Equatable, Sendable { public var id: String /* UserNotice.id */; public var category: String; public var title: String /* 常に "AutoNote" */; public var body: String; public var buttons: [NoticeButton]; public var userInfo: [String: String]; public static func make(_ n: UserNotice) -> NoticeContent; public static func action(category: String, buttonID: String?, userInfo: [String: String]) -> UserNoticeAction? }`（`buttonID` nil は通知そのものを押した場合）
  - `public enum NoticeRelay { public static func notices(for e: RecordingEvent) -> [UserNotice]; public static func notices(previous: QueueStatus, current: QueueStatus) -> [UserNotice]; public static func notices(outputFolderWasAvailable: Bool, isAvailable: Bool) -> [UserNotice] }`
  - `public enum PrivacyPane { public static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!; public static let systemAudio = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")! }`
  - App: `@MainActor final class SystemUserNotifier: NSObject, UserNotifier, UNUserNotificationCenterDelegate { init(onAction: @escaping @MainActor (UserNoticeAction, _ category: String) -> Void, onPost: @escaping @MainActor (UserNotice) -> Void, onWithdraw: @escaping @MainActor (String) -> Void); func requestAuthorization() async }`

通知の中身（overview §3 の 14 case と 1 対 1。category は case 名。○○ は `DeviceRef.name`。文言が要件書にあるものは一字一句そのまま）:

| `UserNotice` | 本文 | ボタン → `UserNoticeAction` |
|---|---|---|
| `deviceConnectedCountdown(d, seconds:)` / `deviceSeenFirstTime(d)` / `deviceAlreadyConnected(d)` / `deviceGoneGrace(d, seconds:)` | 計画 03 の `DeviceNoticeCopy.body(for:)` | `DeviceNoticeCopy.actions(for:)`（取り消す → `.cancelCountdown`、はい / いいえ / 今後聞かない → `.registerDevice(d, answer: .yes / .no / .never)`、開始 → `.startNow(d)`、猶予はボタンなし） |
| `silence(.mic)` | `SilenceMonitor.micMessage`（§5.7） | システム設定を開く → `.openPrivacySettings` |
| `silence(.system)` | `SilenceMonitor.systemMessage`（§5.7） | システム設定を開く → `.openPrivacySettings` |
| `diskLow(availableBytes:)` | ディスクの空きが 1GB を切りました（残り <n> MB）。500MB を切ると録音を止めます［私の判断］ | なし |
| `recordingTooShort(id)` | 1 分未満の短すぎる録音です。文字起こししますか？（§5.9） | 文字起こしする → `.transcribeTooShort(id)`、破棄 → `.discardTooShort(id)` |
| `interruptedRecordingFound(id)` | 前回の録音が途中で終わっています。文字起こしと議事録を作りますか？（§5.8） | はい → `.recoverInterrupted(id)`、破棄 → `.discardInterrupted(id)` |
| `minutesGenerated(id, title:)` | 議事録ができました: <title>［私の判断］ | 開く → `.openMeeting(id)` |
| `transcriptOnly(id)` | 議事録 未生成: 文字起こしだけを書き出しました（§8.4） | 再実行 → `.retry(id)` |
| `claudeNotLoggedIn(id)` | 議事録 未生成: Claude Code にログインしていません。ターミナルで claude を起動してログインしてから再実行してください（§8.4） | 再実行 → `.retry(id)` |
| `overwriteConfirmation(id)` | Vault の会議ファイルがアプリの外で編集されています。上書きしますか？（§8.4） | 上書きする → `.resolveOverwrite(id, overwrite: true)`、残す → `.resolveOverwrite(id, overwrite: false)` |
| `outputFolderMissing` | 出力フォルダが見つかりません（§9.5） | なし |
| `automationFailed(name:, id)` | Automation 失敗: <name>（§14.5） | 開く → `.openMeeting(id)` |

ボタンなしで通知を押したら、`meeting_id` があれば `.openMeeting(id)`、無ければ nil（App はウィンドウを開く）。`userInfo` には `meeting_id`、機材の `name` `uid` `transport`、`track`、`name`（Automation）を入れ、`action` はこれだけから組み直す（アプリの再起動後に押されても動くように）。

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func deviceCasesUseDeviceNoticeCopy()  // 4 case それぞれ body == DeviceNoticeCopy.body(for:)、buttons の title と action が DeviceNoticeCopy.actions(for:) と同じ
@Test func everyOtherCaseHasTableText()      // 表の残り 10 行の body と buttons の title を照合（diskLow(availableBytes: 900_000_000) → "残り 858 MB"）
@Test func buttonsMapBackToActions()         // 14 case すべて、make の各ボタンを action(category:buttonID:userInfo:) に通すと表の UserNoticeAction
@Test func idIsUserNoticeID()                // make(n).id == n.id
@Test func tapWithoutButton()                // minutesGenerated を buttonID nil → .openMeeting(id)、outputFolderMissing → nil
@Test func relayRecordingEvents() {
    #expect(NoticeRelay.notices(for: .silenceWarning(SilenceWarning(track: .mic, message: SilenceMonitor.micMessage))) == [.silence(.mic)])
    #expect(NoticeRelay.notices(for: .diskSpaceLow(availableBytes: 900_000_000)) == [.diskLow(availableBytes: 900_000_000)])
    #expect(NoticeRelay.notices(for: .bookmarked(b)).isEmpty && NoticeRelay.notices(for: .stopped(m, .manual)).isEmpty)   // 短すぎる録音は Task 13 の AppWiring が出す
}
@Test func relayQueueAndFolder()  // 新しく awaitingConfirmation になった件 → [.overwriteConfirmation(id)]（前から同じ状態なら []）。outputFolderWasAvailable true・isAvailable false → [.outputFolderMissing]、他は []
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter NoticeContentTests` → Expected: `cannot find 'NoticeContent' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
Core の 2 ファイルを書く。`SystemUserNotifier`: init で 14 の category を `UNNotificationCategory` として登録。`requestAuthorization` は `[.alert]` だけ（音とバッジは求めない）。`post` は `NoticeContent.make` から `UNMutableNotificationContent` を作り、`sound` は設定しない（nil）。同じ id は置き換わる。続けて `onPost(notice)`（`AppModel.noticePosted`）。`withdraw` は配信済みと待機中の両方から消して `onWithdraw(id)`。`willPresent` は `[.banner, .list]`（音を入れない。overview §3）。`didReceive` は `NoticeContent.action` に通して `onAction(action, category)`。`.openPrivacySettings` は App 側で category と `track` から `PrivacyPane.microphone` か `.systemAudio` を開く。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter NoticeContentTests && swift build --product AutoNoteApp` → Expected: PASS、ビルド成功
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation Sources/AutoNoteApp/SystemUserNotifier.swift Resources/Info.plist Tests/AutoNoteCoreTests/Presentation/NoticeContentTests.swift && git commit -m "feat: silent user notifications with action buttons for all notice cases"`

---

### Task 13: 計画をまたぐ配線（`AppWiring`）とアプリの骨組み（`AppEnvironment.make`、メニューバー、終了確認、起動時の確認、ログイン時起動、ショートカット）

overview §8b の配線の担当。判断は Core の `AppWiring`・`LiveTranscriptionWiring` に置いてフェイクでテストし、App の `AppEnvironment.make` は具体のサービスを順に作って渡すだけにする。計画 00 の骨組みと計画 02 の一時メニューを本番の形に置き換える。

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/AppWiring.swift`, `Sources/AutoNoteCore/Presentation/LiveTranscriptionWiring.swift`
- Create: `Sources/AutoNoteApp/AppEnvironment.swift`, `AppDelegate.swift`, `MenuBarContent.swift`, `HotKeyCenter.swift`, `LoginItem.swift`, `WorkspaceOpener.swift`
- Modify: `Sources/AutoNoteApp/AutoNoteApp.swift`（スパイクの本体を消して書き直す）、`Sources/AutoNoteTestSupport/FakePorts.swift`（`FakeEnqueuer` を足す）
- Delete: `Sources/AutoNoteApp/DevChecks.swift`（計画 02 Task 1 の一時メニュー。overview §8b）
- Test: `Tests/AutoNoteCoreTests/Presentation/AppWiringTests.swift`

**Interfaces:**
- Consumes: 冒頭の表のすべて、Task 2〜12 のすべて
- Produces:
  - `public protocol MeetingEnqueuing: Sendable { func enqueue(_ id: MeetingID) async }`、`public struct QueueEnqueuer: MeetingEnqueuing { public init(_ holder: QueueHolder) }`（計画 05 の `enqueue` が throws ならここで握ってログに残す）。TestSupport `actor FakeEnqueuer: MeetingEnqueuing { var ids: [MeetingID] }`
  - `public actor AppWiring { public init(events: @Sendable @escaping () async -> AsyncStream<RecordingEvent>, enqueuer: any MeetingEnqueuing, notifier: any UserNotifier, listeners: [@Sendable (RecordingEvent) async -> Void] = [], onQueueInputsChanged: @Sendable @escaping (Settings) async -> Void = { _ in }); public func run() async; public func route(_ manifest: Manifest) async; public func settingsChanged(from old: Settings, to new: Settings) async }`
  - `public struct LiveFeedStart: Sendable { public var feed: LiveFeed; public var language: Language; public var hints: [String] }`、`public actor LiveTranscriptionWiring: LiveTranscriptPort { public init(audio: @Sendable @escaping (Track) async -> AsyncStream<AudioChunk>, makeFeed: @Sendable @escaping (MeetingID) async throws -> LiveFeedStart); public func handle(_ e: RecordingEvent) async; public func updates() -> AsyncStream<[Utterance]> }`
  - App: `@MainActor final class AppEnvironment { static func make(environment: [String: String]) async throws -> AppEnvironment; let paths: AppPaths; let settings: SettingsStore; let output: OutputFolderServices; let session: RecordingSession; let coordinator: AutoRecordCoordinator; let registry: DeviceRegistry; let monitor: DeviceMonitor; let queue: QueueHolder; let wiring: AppWiring; let crashRecovery: CrashRecovery; let catalog: EngineCatalog; let models: ModelManager; let automationsFile: AutomationsFile; let ports: AppPorts; let model: AppModel; let notifier: SystemUserNotifier; let server: SocketServer; func settingsSaved(old: Settings, new: Settings) async }`
  - App: `final class AppDelegate: NSObject, NSApplicationDelegate`、`@MainActor final class HotKeyCenter { init(onPress: @escaping @MainActor (ShortcutAction) -> Void); func apply(_ s: Shortcuts) -> [ShortcutAction: OSStatus] }`、`enum LoginItem { static func set(_ on: Bool) throws; static var status: SMAppService.Status { get } }`、`struct WorkspaceOpener: FileOpener`（Obsidian があれば `ObsidianLink.url(for:)`、無ければ既定のアプリ）

- [ ] **Step 1: 失敗するテストを書く**
`m(_ status:)` は `Samples.manifest` の status を替えたもの。`wiring(events:)` は `FakeEnqueuer` と `FakeUserNotifier` で組む。
```swift
@Test func stoppedRecordedIsEnqueued() async      // events に .stopped(m(.recorded), .manual) → enqueuer.ids == [id]、notifier.posted == []
@Test func stoppedTooShortIsNotEnqueued() async   // .stopped(m(.tooShort), .manual) → ids == []、posted == [.recordingTooShort(id)]
@Test func diskFullStopUsesStatusToo() async       // .stopped(m(.recorded), .diskFull) → enqueue（reason ではなく status で決める）
@Test func listenersSeeEveryEvent() async          // listener 2 つ → どちらも [.started, .bookmarked, .stopped] を受ける
@Test func importedManifestIsRouted() async throws // MeetingsAdapter(route: wiring.route).importAudio(3 秒の WAV) → ids == [新しい id]
@Test func recoverYesRoutesRecoveredManifest() async throws  // status .recording の manifest に 61 秒の無音 WAV（WAVFile.header ＋ 0 埋め）→ meetings.recover(id) → ids == [id]。トラックなし → ids == []、posted == [.recordingTooShort(id)]
@Test func queueInputsChangeRebuildsOnlyWhenNeeded() async  // outputFolder か finalEngine か finalModel が変わる → onQueueInputsChanged 1 回。countdownSeconds だけ → 0 回
@Test func liveFeedGetsAudioAndWritesLiveJSON() async throws // makeFeed は FakeLiveTranscriber 2 本の LiveFeed（liveJSON = paths.transcriptFile(id, .live)）。.started(id) → audio(.mic) に流した 2 チャンクが mic の fedChunks に届き、updates() に台本の発話。.stopped → live.json がある
@Test func pauseAndBookmarkBecomeMarkers() async throws      // .paused(10)・.resumed(20)・.bookmarked(25) → 最後の updates() の LiveFeed.isMarker が 2 件
@Test func liveFeedFailureDoesNotBreakRecording() async      // makeFeed が throw → updates() は空のまま、enqueue は通常どおり
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AppWiringTests` → Expected: `cannot find 'AppWiring' in scope` でビルド失敗
- [ ] **Step 3: Core の配線を書く**
- `AppWiring.run()`: `events()` を 1 本購読し、事象ごとに `listeners` を順に呼ぶ。`.stopped(manifest, _)` は `route(manifest)`
- `route`（停止・取り込み完了・復旧の「はい」の共通口。overview §8b (1)(2)）: `status == .tooShort` → `notifier.post(.recordingTooShort(id))`（enqueue しない）。`.recorded` → `enqueuer.enqueue(id)`。他の status はログだけ
- `settingsChanged`: `outputFolder`・`finalEngine`・`finalModel` のどれかが違えば `onQueueInputsChanged(new)`
- `LiveTranscriptionWiring.handle`（§8b (3)）: `.started(id)` → `makeFeed(id)` → `feed.start(language:hints:)` のストリームを `updates()` の購読者へ流し、`audio(.mic)`・`audio(.system)` をそれぞれ 1 本の Task で `feed.feed(_:)` へ。`.paused(t)` → `pause(at: t)`、`.resumed(t)` → `resume(at: t)`、`.bookmarked(b)` → `bookmark(b)`、`.stopped` → 音声の Task を止めて `finish()`（`live.json` は LiveFeed が書く）。`makeFeed` の失敗はログに残し、その会議はリアルタイム表示なしで録音を続ける
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AppWiringTests` → Expected: PASS
- [ ] **Step 5: `AppEnvironment.make` を書く**（この順。各 init の引数は冒頭の表のとおり）
1. `paths = AppPaths.resolve(environment:)`、`paths.createBaseDirectories()`、`settings = SettingsStore(paths:)`、`s = try await settings.load()`、`manifests = ManifestStore(paths:)`
2. `output = OutputFolderServices(paths:)`、`try await output.rebuild(outputFolder: s.outputFolder)`（中で `PortableConfigStore.sync()`。§8b (4)）
3. `session = RecordingSession.live(paths: paths, settings: s)`（clock は既定）
4. `machine = MachineKind` の実行時判定、`models = ModelManager(directory: paths.modelsDirectory)`、`catalog = EngineCatalog(machine:, speech: AppleSpeechCapabilities(), installedModels: { await models.installed().map(\.name) })`、`factory = TranscriberFactory(models:, machine:)`
5. `live = LiveTranscriptionWiring(audio: { await session.audio(for: $0) }, makeFeed: { id in … })`。`makeFeed` は `settings.load()` と `output.portable().read(.dictionary)` を `DictionaryFile.parse` したものから `LiveFeed.make(settings:catalog:factory:dictionary:liveJSON: paths.transcriptFile(id, .live))` を作り、`language` は `coordinator.current().language`、`hints` は辞書の `terms`
6. `notifier = SystemUserNotifier(…)`、`automationsFile = AutomationsFile(url: paths.automationsFile)`、`runner = AutomationRunner(logsDirectory: paths.logsDirectory.appending(path: "automations"), ledgerFile: paths.logsDirectory.appending(path: "automations-ledger.json"))`、`dispatcher = AutomationDispatcher(file:runner:notifier:)`
7. `makeQueue(s)`: `gate = BatchGate()`、`choice = catalog.resolve(role: .batch, language: s.defaultLanguage, override: EngineChoice.fromSettings(kind: s.finalEngine, model: s.finalModel, role: .batch, machine:))`、`FinalTranscriptionRunner(transcriber: LazyBatchTranscriber(factory:, choice:, gate:), engineName: choice.displayName, paths:, gate:)` を計画 05 の `TranscribeStage` に渡し（`LazyBatchTranscriber` は本ファイル内の委譲型で、初回の `transcribe` で `factory.makeBatch(choice, gate:)` を呼ぶ。モデル未取得はそのジョブの失敗になり、起動は止めない。`choice` が nil なら `EngineCatalog.defaults(for: machine).batch`）、`SummarizeStage`・`WriteVaultStage`・`UpdateIndexStage`、**最後に** `AutomationsStage(dispatcher:, notifier:, vault: { await output.vault() })` を並べて `PostProcessingQueue(paths:, stages:, activity: 計画 05 の RecordingActivity アダプタ(session.events から))`（§8b (5)）。`queue = QueueHolder(makeQueue(s))`
8. `registry = DeviceRegistry(storage: CurrentDevicesStorage(output:, paths:), mac: SystemMacIdentityProvider())`（`CurrentDevicesStorage` は本ファイル内の委譲型で、呼ばれるたびに `output.portable()` の `PortableDevicesStorage(store:paths:)` に渡す。出力先が変わっても registry を作り直さない）、`monitor = DeviceMonitor(hardware: CoreAudioHardware(), power: WorkspaceSleepWakeObserver(), timer: TaskTimerScheduler())`、`coordinator = AutoRecordCoordinator(monitor:, registry:, recorder: RecordingSessionControl(session:), notifier:, timer: TaskTimerScheduler(), config: { AutoRecordCoordinator.config(from: (try? await settings.load()) ?? Settings()) })`
9. `trigger = RecordingAutomationTrigger(dispatcher:, manifests:)`、`wiring = AppWiring(events: { await session.events() }, enqueuer: QueueEnqueuer(queue), notifier:, listeners: [{ await live.handle($0) }, { await trigger.handle($0) }, { e in for n in NoticeRelay.notices(for: e) { await notifier.post(n) } }], onQueueInputsChanged: { s in await rebuildQueue(s) })`。`rebuildQueue` は `output.rebuild(outputFolder: s.outputFolder)` → 古い queue を `stop()` → `queue.replace(makeQueue(s))` → `start()` → `registry.reload()`（§8b (4)。ジョブはファイルにあるので作り直しで失われない）
10. `crashRecovery = CrashRecovery(paths:, manifests:)`、`importer = AudioImporter(paths:, manifests:)`、アダプタで `ports = AppPorts(…)`（`MeetingsAdapter(…, route: { await wiring.route($0) })`、`live` は `LiveTranscriptionWiring` そのもの）、`model = AppModel(ports:)`、`server = SocketServer(socketURL: paths.socketFile, handler: CommandRouter(ports:))`
11. `settingsSaved(old:new:)` は設定画面の保存から呼ばれ、`wiring.settingsChanged(from:to:)`、`HotKeyCenter.apply(new.shortcuts)`、`LoginItem` の突き合わせをする

`applicationDidFinishLaunching` の順番:
1. `AppEnvironment.make(environment: ProcessInfo.processInfo.environment)`。`server.start()` が `.alreadyRunning` ならログに書いて `NSApp.terminate(nil)`
2. `notifier.requestAuthorization()`。Task で `wiring.run()`、`queue.start()`、`model.run()`、計画 05 の `RetentionScheduler.start()` を起こす。待ち行列の `snapshots()` と `model.outputFolderAvailable` の変化は `NoticeRelay` に通して `notifier.post`
3. クラッシュ復旧（録音を始める前）: `crashRecovery.findInterrupted(excluding: nil)` の各件に `post(.interruptedRecordingFound(id))`。「はい」は `.notice(.recoverInterrupted(id))` → `meetings.recover` → `route`（§5.8・§8b (2)）。その後に `coordinator.run()` を起こす
4. 初回注意書き: `consentNoticeShown == false` なら小さなウィンドウ（`Window` scene、id `consent`）で「録音は相手の同意を得て行ってください」と「OK」。OK で `settings.update { $0.consentNoticeShown = true }`（§11.6）
5. マイク許可: `AVMicrophonePermission().status() == .notDetermined` なら `AVCaptureDevice.requestAccess(for: .audio)` を呼ぶ（計画 02 は要求しない。注意書きの OK の後）。`.denied` のときは録音開始の失敗が `lastError` と帯に出る
6. ログイン時起動の突き合わせ: `launchAtLogin` と `LoginItem.status` が食い違えば設定に合わせて `register`/`unregister`
7. `HotKeyCenter.apply(s.shortcuts)`。`.bookmark` → `perform(.bookmark(nil))`、`.toggleRecording`、`.togglePause`

`applicationShouldTerminate`: `QuitPolicy.decide(model.recorder.state, reason:)`。`confirm` は `NSAlert`（本文 `QuitPolicy.confirmMessage`、ボタン「停止して終了」「キャンセル」）。停止を選んだら `.terminateLater` を返し、`perform(.stop)` の完了（最大 10 秒）を待って `NSApp.reply(toApplicationShouldTerminate: true)`。`NSWorkspace.willPowerOffNotification` と SIGTERM（`signal(SIGTERM, SIG_IGN)` の後 `DispatchSource.makeSignalSource`）は `reason = .powerOff`。`cancelCountdownThenTerminate` は取り消してから終了。`applicationWillTerminate` で `server.stop()`（ソケットを消す。E2E 06.6 が見る）。
- [ ] **Step 6: 画面とホットキーを書く**
- `AutoNoteApp`: `@NSApplicationDelegateAdaptor(AppDelegate.self)`。`MenuBarExtra { MenuBarContent } label: { … }`。label はアイドル時 `Image(systemName: "waveform")` だけ（計画 00 の E2E 7b の項目名を保つ）。録音中・一時停止中・猶予中は `TimelineView(.periodic(from: .now, by: 1))` で `Image(systemName: p.symbol)` と `Text(p.title)`
- `MenuBarContent`: `model.menuBar(now:)` の `items` を順に描く。文言: 録音開始 / 停止 / 一時停止 / 再開 / ブックマーク / 取り消す / 言語（自動・日本語・英語。§6.4）/ ウィンドウを開く / 最新の議事録を開く / 設定…（`SettingsLink`）/ 終了（⌘Q）。`.status` は押せない行。`.minutesMissing` は `.regenerate`、`.automationFailed` は `.rerunAutomation`
- `HotKeyCenter`: `apply` は `ShortcutBindings(s)` の各 `combo(for:)` を Carbon `RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x414E4F54 /* 'ANOT' */, id: 番号), GetEventDispatcherTarget(), 0, &ref)` で登録する（前の登録は全部外す。読めない文字列は登録しない）。`InstallEventHandler`（`kEventClassKeyboard` / `kEventHotKeyPressed`）。アクセシビリティ許可は不要
- `LoginItem`: `SMAppService.mainApp.register()` / `unregister()`。`.requiresApproval` なら `SMAppService.openSystemSettingsLoginItems()`
- [ ] **Step 7: ビルドして起動を確かめる** — Run: `swift build && scripts/build-app.sh && open build/AutoNote.app` → Expected: ビルドと `codesign --verify` が通る。`grep -rn DevChecks Sources` が 0 件
確認する（実装者）: メニューバーに waveform のアイコンがあり、メニューに「録音開始」「ウィンドウを開く」「最新の議事録を開く」「設定…」「終了」がある（「取り消す」は無い）。初回は注意書きのウィンドウが出て、OK 後に再起動すると出ない。`build/AutoNote.app/Contents/MacOS/autonote status` が「録音器: 待機」を返す。⌃⌥B を押しても落ちない。

👤 利用者（マイク・システム音声・通知の許可が要る）: 「録音開始」→ 経過時間が進み、⌃⌥B でブックマーク、⌃⌥P で一時停止と再開。停止すると待ち行列に入る（`autonote status` に 1 件）。30 秒で止めると「1 分未満の短すぎる録音です」の通知（音なし）。録音中に「終了」→ 確認が出る。ログイン時起動をオンにしてログアウト・ログインで常駐する。通知のスタイルが「通知パネル」になっている
- [ ] **Step 8: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed（計画 00 の 7・7b は waveform のまま PASS）。続けて `git add Sources/AutoNoteCore/Presentation Sources/AutoNoteApp Sources/AutoNoteTestSupport Tests/AutoNoteCoreTests/Presentation && git rm Sources/AutoNoteApp/DevChecks.swift && git commit -m "feat: cross-plan wiring, app shell, quit confirmation, login item and hotkeys"`

---

### Task 14: メインウィンドウ

**Files:**
- Create: `Sources/AutoNoteApp/MainWindow/MainWindow.swift`, `MeetingListView.swift`, `StatusHeader.swift`, `LiveTranscriptView.swift`, `RecordingDetailView.swift`, `ProcessingDetailView.swift`, `CompletedDetailView.swift`, `MinutesEditor.swift`, `TooShortView.swift`, `ImportSheet.swift`
- Modify: `Sources/AutoNoteApp/AutoNoteApp.swift`（`Window("AutoNote", id: "main")` を足す）

**Interfaces:**
- Consumes: `AppModel`, `UserAction`, `LiveLine`, `ObsidianLink`, `NoticeContent`（Task 11・12）、`MeetingsPort`（`manifest`・`minutes`・`transcript(_:kind:)`・`saveMinutes(_:_:renameFile:overwrite:)`。Task 8）、`TranscriptKind.live` / `.final`、`Replacer`（計画 01）、`AudioImporter.supportedExtensions`（計画 02）、`WorkspaceOpener`（Task 13）
- Produces: `struct MainWindow: View`（`NavigationSplitView`。左 `MeetingListView`、右は選んだ会議の `MeetingRow.state` で切り替える）

- [ ] **Step 1: 画面を書く**
- `StatusHeader`: 録音中・一時停止中・猶予中は選択に関係なく「録音中」か「一時停止中」と経過時間（§5.3）。猶予中は `recorder.banner`（「機材が外れました。N 秒後に停止」）。`diskWarning`、「出力フォルダが見つかりません」（§9.5）、`lastError`、`model.prompts` の各件（`NoticeContent.make` の本文とボタン。押すと `.notice(action)`）も帯で出す
- 左の一覧: `model.meetings`。日付・時刻・タイトル・長さ・状態（Task 10 と同じ表示語）、`progressLabel`、無音警告の印（`exclamationmark.triangle`）、「Automation 失敗: ○○」の印
- 録音中: 停止・一時停止（再開）・ブックマークのボタン、言語の切替。`LiveTranscriptView` は `model.live.lines`。`.utterance` は時刻（`TimelineTime.hhmmss`）・話者（自分 / 相手 / 不明）・本文で、`isFinal == false` は `.foregroundStyle(.secondary)`（§6.3 薄い色）。`.marker` は本文（LiveFeed の文言）を区切り行で出し、ブックマークには `bookmark.fill`。`.defaultScrollAnchor(.bottom)` で追従し、`onScrollGeometryChange` で最下部から離れたら追従をやめて「最新へ」ボタン。押すと最後の行へ戻り追従を再開
- 処理中: 進捗（`ProgressView(value:)` と `progressLabel`）と、`transcript(id, kind: .live)` を辞書の `Replacer` に通したもの（`live.json` は置換前。§7.1）を同じ見た目で（読み取り専用、追従なし）
- 短すぎる録音: 「1 分未満の短すぎる録音です」と「文字起こしする」→ `.notice(.transcribeTooShort(id))`、「破棄」→ `.notice(.discardTooShort(id))`（§5.9）
- 議事録 未生成（`transcript_only`・`failed`）: 「議事録 未生成」と「再実行」→ `.regenerate(id)`（§8.4）。確定版（`.final`）の文字起こしを下に出す
- 完了: `MinutesEditor` でタイトルと各節（3 行要約、決定事項、議題、Next Action の内容・担当・期限）を編集。ブックマーク一覧、確定版文字起こし（読み取り専用、§9.4）。「保存」: タイトルが変わっていれば「ファイル名も変更する」のチェック（既定オフ。§9.1）→ `saveMinutes(…, overwrite: false)`。`.externallyEdited` なら「Vault の会議ファイルがアプリの外で編集されています。上書きしますか？」で確かめ、はいなら `overwrite: true` で呼び直す。「再生成」は `.regenerate(id)`（外部編集の確認は計画 05 の `write_vault` が待ちにし、`overwriteConfirmation` の通知と帯で聞く）。「Obsidian で開く」→ `WorkspaceOpener`。「この会議を削除」→ 確認「この会議を削除しますか？音声、アプリ内のデータ、Vault の会議ファイル、_index.md の行をまとめて削除します。元に戻せません。」の後 `.delete(id)`（§12）
- 取り込み: ウィンドウ全体の `.dropDestination(for: URL.self)`（拡張子は `AudioImporter.supportedExtensions`）とツールバーの「音声ファイルを取り込む…」（`NSOpenPanel`）。`ImportSheet` で日時を選ばせる（既定はファイルの作成日時 `URLResourceValues.creationDate`。§10）→ `.importAudio(url, startedAt:)`
- 通知の `.openMeeting(id)` で `selectedMeetingID` が変わったらウィンドウを開いてその会議を選ぶ
- [ ] **Step 2: ビルドが通ることを確かめる** — Run: `swift build && scripts/build-app.sh` → Expected: 成功
- [ ] **Step 3: 起動して確かめる**
Run: `autonote dev render-fixture --out /tmp/an-vault`（計画 01）で架空の会議を書き、設定の出力フォルダ（`Settings.outputFolder`。Task 15 の前なら `settings.json` を計画 01 の形で手で）を `/tmp/an-vault` にして `open build/AutoNote.app`
確認する（実装者）: 一覧にフィクスチャの会議が出て、選ぶと議事録・ブックマーク・文字起こしが出る。「Obsidian で開く」で Obsidian（無ければ既定のエディタ）が開く。タイトルを変えて保存すると、チェックなしでは Vault のファイル名が変わらず frontmatter の title と `_index.md` が変わる。Vault のファイルを外で書き換えてから保存すると上書きの確認が出る。`/tmp/an-vault` を別名に移すと 30 秒以内に「出力フォルダが見つかりません」の帯と通知が出て、戻すと帯が消える。音声ファイルをドラッグすると日時のシートが出て、取り込むと一覧に処理中で現れる。

👤 利用者: 2 分ほど録音し、リアルタイム文字起こしが流れ、部分結果が薄い色で出ること、上へスクロールすると追従が止まり「最新へ」で戻れること、ブックマークと一時停止の印が出ることを見る。30 秒で止めた録音が「短すぎる録音」になり「文字起こしする」「破棄」が効くこと
- [ ] **Step 4: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed。続けて `git add Sources/AutoNoteApp && git commit -m "feat: main window with meeting list, live transcript and minutes editor"`

---

### Task 15: 設定画面（8 タブ）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/SettingsDrafts.swift`
- Create: `Sources/AutoNoteApp/Settings/SettingsView.swift`, `GeneralTab.swift`, `DevicesTab.swift`, `TranscriptionTab.swift`, `DictionaryTab.swift`, `MinutesTab.swift`, `AutomationsTab.swift`, `RetentionTab.swift`, `ShortcutsTab.swift`, `ShortcutRecorderField.swift`
- Modify: `Sources/AutoNoteApp/AutoNoteApp.swift`（`Settings { SettingsView() }` scene）
- Test: `Tests/AutoNoteCoreTests/Presentation/SettingsDraftsTests.swift`

**Interfaces:**
- Consumes: 下の表の各項目（`Settings` の名前と型は overview §3 の一覧そのまま）、`AutoRecordCoordinator.config(from:)`・`AutoRecordConfig`（計画 03。秒数の丸め）、`AutomationsFile`, `AutomationsPort`（Task 3・8）、`KeyCombo`, `ShortcutAction`, `ShortcutBindings`（Task 11）、`AppEnvironment.settingsSaved`, `LoginItem`（Task 13）
- Produces:
  - `public struct DictionaryDraft: Equatable, Sendable { public var terms: [String]; public var replacements: [Replacement]; public var fillers: [String]; public init(_ f: DictionaryFile); public func toFile() throws(AppCommandError) -> DictionaryFile }`
  - `public struct AutomationDraft: Equatable, Sendable { public var definition: AutomationDefinition; public static func validate(_ d: AutomationDefinition, existing: [AutomationDefinition]) -> [String] }`
  - `public enum SettingsNormalizer { public static func normalized(_ s: Settings) -> Settings }`（`countdownSeconds`・`disconnectGraceSeconds` を `AutoRecordCoordinator.config(from:)` の丸めた値で書き戻し、`audioRetentionDays` の負は 0 に。本計画は独自の範囲を持たない）

| タブ | 項目 | 読み書き先 | 備考 |
|---|---|---|---|
| 一般 | 出力フォルダ | `Settings.outputFolder: String?`（パス） | `NSOpenPanel`（フォルダ）。保存で `settingsSaved` → 待ち行列と `_autonote/` を組み直す（Task 13） |
| 一般 | ログイン時起動 | `launchAtLogin: Bool` ＋ `LoginItem.set` | `.requiresApproval` なら「システム設定で許可してください」とボタン |
| 一般 | `claude` のパス / モデル | `claudePath: String?` / `claudeModel: String?` | 「探す」で `/bin/zsh -lc 'command -v claude'`。モデルが空なら Claude Code の既定（§8.1） |
| 一般 | 要約器の種別 | `summarizerKind: SummarizerKind` | 選択肢は `.claudeCode`（表示「Claude Code」）だけ（§8.5） |
| 一般 | CLI | なし | `sudo mkdir -p /usr/local/bin && sudo ln -sf "<Bundle>/Contents/MacOS/autonote" /usr/local/bin/autonote` を表示してコピーボタン（§16） |
| 一般 | 外部送信 | なし | 固定文「音声・文字起こし・議事録はこの Mac に保存します。外部へ送るのは、議事録を作るときに Claude Code へ渡す文字起こしテキスト（全文、辞書の用語、ブックマーク）だけで、音声は送りません。」（§17） |
| 機材 | 接続中・登録済み・無視 | `DeviceMonitor.connected()`、`DeviceRegistry.entries()`・`register(_:startOnModelMatchDefault:)`・`ignore(_:)`・`remove(entryID:)` | `RegisteredDevice` の表示名・方式・識別子・登録した Mac。別の Mac で登録した機材には「この Mac で再登録」（§9.5・11.3） |
| 機材 | 型番一致で開始 | 既定 `startOnModelMatch: Bool`、機材ごと `DeviceRegistry.setStartOnModelMatch(entryID:_:)` | §11.2 |
| 機材 | カウントダウン / 切断猶予の秒数 | `countdownSeconds: Int`（0〜30）/ `disconnectGraceSeconds: Int`（5〜300） | Stepper の範囲は overview §3 の値。保存前に `SettingsNormalizer` |
| 文字起こし | リアルタイム / 確定版のエンジンとモデル | `liveEngine` `liveModel` / `finalEngine` `finalModel: String?` | 選択肢は `EngineCatalog.entries(role: .live / .batch, language: defaultLanguage)`。`available == false` は `reason` を添えて選べない（§6.2）。保存は `entry.choice.kind.rawValue`（`"dictation"` `"speech"` `"whisper"`）と `choice.model`。今の値は `EngineChoice.fromSettings(kind:model:role:machine:)`、nil なら `catalog.resolve(…, override: nil)` を「既定」として出す |
| 文字起こし | モデルのダウンロード | `WhisperModelCatalog.all`、`ModelManager.installed()`・`download(_:progress:)`・`delete(_:)` | 大きさと進捗。未取得のモデルを選んだら注意 |
| 文字起こし | 既定の言語 / エコー除去 / フィラー除去 | `defaultLanguage: Language` / `voiceProcessing: Bool` / `fillerRemoval: Bool` | §6.4。エコー除去は「他のアプリの音が小さくなることがあります。次回の起動から効きます」（§5.6。`RecordingSession` は起動時の設定で作るため）。§6.5 |
| 辞書 | 用語・置換・フィラー | `PortableConfigStore.read(.dictionary)` / `write(.dictionary, _:)`、`DictionaryFile.parse` / `render` | タブを開くときとウィンドウが前面に来たときに読み直す（§7.2。計画 00 の申し送り）。未保存の編集があるときは上書きしない |
| 議事録 | プロンプト | `read(.prompt)` / `write(.prompt, _:)` | `TextEditor`（§8.3）。空なら `DefaultPrompt.instructions` を出す |
| 議事録 | frontmatter テンプレート | `read(.frontmatter)` / `write(.frontmatter, _:)` | 「`FrontmatterTemplate.requiredKeys`（title・date・status・autonote_id）はテンプレートから消しても必ず付きます」と注記（§9.2） |
| Automations | 定義 / 手動実行 / 実行ログ / 書き出し・読み込み | `AutomationsFile.load/save/export/importReplacing`、`AutomationsPort.run(name:meetingID:)`・`recentRuns(limit: 50)` | 追加・編集・削除。権限の警告は上に帯で（§14.2）。ログは時刻・名前・会議・終了コード／タイムアウト・所要時間、stdout/stderr の末尾とフォルダを開く |
| 保持 | 音声の保持日数 | `audioRetentionDays: Int`（既定 30、0 で削除しない） | §12。計画 05 の `RetentionScheduler` が読む |
| ショートカット | ブックマーク、録音開始・停止、一時停止 | `Settings.shortcuts`（`Shortcuts` の文字列） | `ShortcutRecorderField` で `KeyCombo` を作り、`ShortcutAction.keyPath` に `combo.description` を書く。保存後 `HotKeyCenter.apply`。失敗は「このショートカットは他のアプリが使っています」 |

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func dictionaryDraftTrimsAndDropsEmpty() throws          // terms ["AutoNote", "  所沢 ", ""] → toFile().terms == ["AutoNote", "所沢"]
@Test func dictionaryDraftRejectsHalfEmptyReplacement()        // [オートノート => AutoNote, クーバ => " "] → throws .invalid("置換の左右どちらかが空です（2 行目）")
@Test func automationDraftValidation()   // 名前 "" → ["名前を入れてください"]、command " " → ["コマンドを入れてください"]、timeout 0 → ["タイムアウトは 1〜86400 秒にしてください"]、既存と同名 → ["同じ名前の Automation があります"]
@Test func normalizerUsesAutoRecordConfig() {   // countdownSeconds 45 → 30、-1 → 0、disconnectGraceSeconds 0 → 5、999 → 300、audioRetentionDays -3 → 0
    var s = Settings(); s.countdownSeconds = 45; s.disconnectGraceSeconds = 0
    let n = SettingsNormalizer.normalized(s)
    #expect(n.countdownSeconds == AutoRecordCoordinator.config(from: s).countdownSeconds && n.disconnectGraceSeconds == 5)
}
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter SettingsDraftsTests` → Expected: `cannot find 'DictionaryDraft' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
`SettingsDrafts.swift` を書いて通す。続けて各タブを表どおりに書く。保存は各タブの「保存」で、`old = settings.load()` → `SettingsNormalizer.normalized(new)` を `settings.save` → `env.settingsSaved(old:new:)`。`ShortcutRecorderField` は入力欄にフォーカスがある間だけ `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` でキーを拾い（アプリ内なので許可不要）、`KeyCombo.validate` と `ShortcutBindings.duplicates` に引っかかれば保存させない。Automations の編集シートは名前・きっかけ（4 択）・コマンド（`TextEditor`）・タイムアウト秒で、`AutomationDraft.validate` の結果を下に出す。
- [ ] **Step 4: 通過とビルドを確かめる** — Run: `swift test --filter SettingsDraftsTests && scripts/build-app.sh` → Expected: PASS、ビルド成功
- [ ] **Step 5: 起動して確かめる**
Run: `open build/AutoNote.app` → メニュー「設定…」
確認する（実装者）: 8 タブが並ぶ。辞書を編集・保存すると `<出力フォルダ>/_autonote/dictionary.md` が変わり、外で書き換えてタブを開き直すと反映される。プロンプトと frontmatter も同様。出力フォルダを変えると新しいフォルダに `_autonote/` ができる。猶予を 3 にして保存すると 5 になる。Automations に `echo "$AUTONOTE_EVENT" >> /tmp/an-auto.txt` を足し、手動実行でログ一覧に 1 行増え、`/tmp/an-auto.txt` に `minutes_generated` が書かれる。`chmod 664` で警告の帯が出る。ショートカットを ⌃⌥K に変えると `settings.json` の `bookmark` が `"ctrl+option+k"` になり、⌃⌥B が効かなくなる（録音中の確認は 👤）。
👤 利用者: モデルのダウンロード（ネットワークと数百 MB の空き）、ログイン時起動のオン・オフ
- [ ] **Step 6: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed。続けて `git add Sources/AutoNoteCore/Presentation/SettingsDrafts.swift Sources/AutoNoteApp Tests/AutoNoteCoreTests/Presentation/SettingsDraftsTests.swift && git commit -m "feat: settings window with eight tabs"`

---

### Task 16: E2E 更新（7/7b の拡張と Automations）、全 PASS、README 更新、コミット

**Files:**
- Modify: `scripts/e2e-check.sh`（計画 00 の `check_app_launch` の起動方法、06.2〜06.6 の項目、CHECKS 配列、先頭の説明）
- Modify: `README.md`

**Interfaces:**
- Consumes: `AUTONOTE_DATA_DIR`（計画 01 `AppPaths.resolve`）、`AUTONOTE_CLI`・`need_autonote_cli`（計画 01 の E2E 補助）、`autonote status --json` / `bookmark` / `automations run`（Task 10）、フィクスチャ `Tests/Fixtures/meetings/20261024-1400-a1b2/{manifest.json, minutes.json}`（計画 01）
- Produces: E2E 項目 06.2〜06.6（06.1 は Task 2）。計画 00 の 7・7b は名前を変えない

- [ ] **Step 1: E2E の項目を書く**
CLI はすべて `"${AUTONOTE_CLI}"` で呼ぶ（無ければ `need_autonote_cli` が SKIP にする）。`ID=20261024-1400-a1b2`、`FIX=Tests/Fixtures/meetings/${ID}`。
- 先頭で `DATA="$(mktemp -d /tmp/an-e2e.XXXXXX)"` を作り（ソケットのパスを短く保つ。Review Focus 1）、`cleanup` で消す
- 計画 00 の 7「AutoNoteApp を起動」: 起動前に `${DATA}/automations.json` を 0600 で書く（下の定義）、`${FIX}/manifest.json` を `${DATA}/recordings/${ID}/manifest.json` に、`${FIX}/minutes.json` を `${DATA}/transcripts/${ID}/minutes.json` に写す。`AUTONOTE_DATA_DIR="${DATA}" AUTONOTE_E2E_OUT="${DATA}/auto-out.txt" "${bin}" &` で起動し、プロセスは 06.6 まで生かす（今の「7b の後に kill」を 06.6 へ移す）。7b は今のまま（アイドル時の項目名 `waveform`）
- `CURRENT="06.2 アプリ未起動の CLI は自動起動しない"`（CHECKS で 7 の前）: `AUTONOTE_DATA_DIR="${DATA}" "${AUTONOTE_CLI}" status` が 3 秒以内に終了コード 1・stderr「AutoNote が起動していません」
- `CURRENT="06.3 autonote status がソケット経由で idle"`: 最大 10 秒 `[[ -S "${DATA}/autonote.sock" ]]` を待ち、`status --json` の出力を `plutil -extract recorder.state raw -o - -` に通して `idle`、終了コード 0。人向けの `status` が「録音器: 待機」を含む
- `CURRENT="06.4 録音していないときの bookmark は失敗"`: 終了コード 1、stderr に「録音中ではありません」
- `CURRENT="06.5 Automation の手動実行"`: `automations run e2e-echo ${ID}` が終了コード 0。`${DATA}/auto-out.txt` が `minutes_generated ${ID}` の 1 行
- `CURRENT="06.6 Automation のログとソケットの後始末"`: `${DATA}/logs/automations/*/result.json` が 1 つあり `plutil -extract exit_code raw` が 0、`stdout.txt` がある。ここでアプリに SIGTERM を送り、5 秒以内に `${DATA}/autonote.sock` が消える
- 7 が SKIP（GUI なし）なら 06.3〜06.6 も「アプリが起動していない」で SKIP

Automations の定義（E2E 用の偽コマンド）:
```json
[{"name": "e2e-echo", "enabled": true, "on": "minutes_generated", "command": "echo \"$AUTONOTE_EVENT $AUTONOTE_MEETING_ID\" > \"$AUTONOTE_E2E_OUT\"", "timeout_sec": 30}]
```
- [ ] **Step 2: 失敗を検出できることを確かめる** — 既存の `E2E_EXPECT_VERSION` と同じく、期待値だけを変える環境変数 `E2E_EXPECT_RECORDER_STATE`（既定 `idle`）と `E2E_EXPECT_AUTOMATION_OUT`（既定 `minutes_generated <ID>`）を足し、先頭の説明に書く。Run: `E2E_EXPECT_RECORDER_STATE=recording scripts/e2e-check.sh --quick; E2E_EXPECT_AUTOMATION_OUT=x scripts/e2e-check.sh --quick` → Expected: 1 回目は 06.3、2 回目は 06.5 が FAIL（どちらも終了コード 1）
- [ ] **Step 3: README を更新する** — 足す節: 「使い方（CLI）」（§16 の表を短く。`/usr/local/bin` へのリンクは設定 › 一般に案内がある）、「Automations」（`~/Library/Application Support/AutoNote/automations.json`、§14.6 の例、権限 600、`/bin/zsh -lc`、環境変数の一覧、ログの場所）、「ショートカット」（既定 ⌃⌥B / ⌃⌥R / ⌃⌥P、アクセシビリティ許可は不要）、「通知」（音は鳴らない。表示スタイルは通知パネル）、「ログイン時起動」（`build/AutoNote.app` を動かすと登録先が変わるので、使う場所に置いてからオンにする）、「開発用: `AUTONOTE_DATA_DIR`」（設定すると CLI はアプリを自動起動しない）、`scripts/config.sh`（Bundle ID と証明書名はここだけで変える）
- [ ] **Step 4: 全 PASS を確かめる** — Run: `swift test && scripts/e2e-check.sh` → Expected: テスト全 PASS、`N passed, 0 failed, M skipped`。06.1〜06.6 と 7 が PASS（GUI がある機械で。7b はアクセシビリティ権限が無ければ SKIP でよい）
- [ ] **Step 5: コミット** — `git add scripts/e2e-check.sh README.md && git commit -m "test: e2e covers socket status, bookmark error and automation run; docs for CLI and automations"`

---

## Self-Review（保存前に実施した結果）

1. 要件書の対応: §3.2（`SMAppService.mainApp` 13、`UNUserNotificationCenter` 12、UNIX ソケット 6・7）、§4.1 の 1〜8（常駐 13、通知と取り消し 11〜13、表示 14、ブックマーク 11・13、猶予表示 11・14、進捗 11・14、完了通知と Automations 5・12、編集 14）、§5.3〜5.5・5.8・5.9（11・13・14）、§6.3（11・14）、§7.2（15）、§8.3・8.4（12・14・15）、§9.1・9.5（8・14・15）、§11.3・11.4・11.6（12・13・15）、§14 全部（3〜5・15）、§15（1・13〜15）、§16（6・9・10）、§17（15、Automations の stdin に本文を入れない）、M4（2）。overview §8b の配線 (1)〜(5) は Task 13 の Step 3・5 にあり、それぞれ `AppWiringTests` で enqueue・通知・live.json を確かめる
2. ステップ: 各実装ステップに名前・ファイル・決めた値（秒数、文言、パス、記号名）を入れた。関数本体は書いていない（`config.sh` は設定値そのものなので全文）
3. 型の一致: 冒頭の表の名前を各タスクの Consumes と突き合わせた。`TranscriptKind`・`Settings`（`disconnectGraceSeconds`・`finalEngine`・`summarizerKind: SummarizerKind`・`audioRetentionDays: Int`・`outputFolder: String?`・`shortcuts`・`consentNoticeShown`）・`UserNotice`/`UserNoticeAction`・`FakeUserNotifier`・`RecorderSnapshot`・`LiveFeed.isMarker`・`Job.generation`・`VaultWriter.write(_:policy:renameToMatchTitle:)` は本計画で定義し直していない。本計画が作る型は Task 2〜15 の Produces で 1 回ずつ定義し、`QueueStatus`（Task 8）を画面・CLI・通知が共通に使う（計画 05 の `QueueSnapshot` を直接見るのは `QueueAdapter` だけ）。`runOne` は `AppCommandError`（Task 8）と同じタスクで足す
4. Review Focus: 5 件とも担当タスクのテスト名を入れた（Task 4・7・11）。並列接続（Task 7 `concurrentClients`）、壊れた行（`badLineGetsBadRequest`）、壊れた automations.json（Task 3）もテストにある
5. 残る前提: 計画 05 は改訂中で、`PostProcessingQueue` の init・`enqueue` の throws・`JobProgress` の状態名・`SummaryFailure` の値・4 段階の init は 05 の確定版に合わせて Task 8 の `QueueAdapter` と Task 13 の Step 5 だけを直す。`RecordingActivity` のアダプタ名も 05 に従う
