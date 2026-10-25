# AutoNote 計画 06: 画面・CLI・Automations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 計画 01〜05 のサービスをつなぎ、メニューバー・メインウィンドウ・設定画面・通知・グローバルショートカット・ログイン時起動、UNIX ソケット経由の CLI `autonote`、議事録生成後の Automations を作って、要件書 §4.1 の流れを利用者が端から端まで使える状態にする。

**Architecture:** 画面に依存しない部分（ソケットの JSON 行プロトコル、サーバーとクライアント、CLI の解釈と表示、Automations の読み込み・実行・待ち行列の段階、サービスを束ねる窓口 `*Port`、UI 用の状態集約 `AppModel` と表示規則）はすべて `AutoNoteCore` に置き、フェイクの Port を使って Swift Testing で確かめる。`AutoNoteApp` には SwiftUI の画面と、`UNUserNotificationCenter`・Carbon ホットキー・`SMAppService` をつなぐ薄いコード、サービスを組み立てる起点だけを置く。ソケットの要求は `CommandRouter`（MainActor に乗らない）がサービスへ直接渡すので、画面がモーダル表示中でも CLI は止まらない。

**Tech Stack:** Swift 6 / SwiftUI（`MenuBarExtra`、`Window`、`Settings`）/ Observation / POSIX の UNIX ドメインソケット / UserNotifications / Carbon `RegisterEventHotKey` / ServiceManagement `SMAppService.mainApp` / `posix_spawn`（Automations）/ Swift Testing / bash（scripts）

**Spec:** `docs/superpowers/specs/2026-10-24-autonote-design.md`（要件書。正）と `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md`（計画 01〜06 の共通契約。名前と形はここに従う）

## Global Constraints

- 最低 OS: macOS 26.0。`Package.swift` の platforms は `.macOS("26.0")`、`swiftLanguageModes: [.v6]`
- Intel（x86_64）と Apple Silicon（arm64）の両方でビルド・動作すること。機種依存の分岐は実行時判定（`isAvailable` など）で行い、`#if arch` で機能を落とさない
- 署名: 自己署名証明書 `AutoNote Dev`、Bundle ID `com.yutaokoshi.autonote`。`scripts/build-app.sh` を使う。App Sandbox なし、Hardened Runtime なし
- 音声・文字起こし・議事録・個人の機材識別子（MAC アドレス）をリポジトリにコミットしない。テストのフィクスチャは架空の内容にする
- 音声はローカルから出ない。外部へ渡すのは `claude -p` への文字起こしテキストだけ（要件書 G9）
- 共有する型とプロトコルは本書 §3・§4 の名前と形を使う。変えるなら本書を先に直す
- 利用者の手が要る手順は「👤 利用者」と明記し、実装者はそこで止めて依頼する
- 各タスクは TDD（失敗するテスト → 実装 → 通過 → コミット）。ハードウェアが要る部分だけ手動確認手順を書く
- コミットメッセージは英語の Conventional Commits。タスクごとにコミット。push はしない
- 実装者はタスク完了前に `scripts/e2e-check.sh` を回し、結果を報告に含める

（「本書」は overview を指す。）

## Review Focus

要件書から読み取れるが、素直に作ると誰のテストにも引っかからず、利用者が踏みやすいもの。各行のテストは担当タスクに入れてある。

1. ソケットのパスが `sun_path` の上限（104 バイト、終端 NUL を含む）を超える（ホームが長い、`AUTONOTE_DATA_DIR` を深い場所にした）。黙って切り詰めず、分かるエラーで止まる（Task 6 `pathTooLongIsRejected`）
2. アプリが起動できない（`open -b` が失敗する、起動しても 10 秒以内にソケットが現れない）ときに CLI がずっと待ち続ける。10 秒で終了コード 1 と理由を出す（Task 6 `clientTimesOutWhenAppNeverAppears`・`launcherFailureIsReported`）
3. Automation のコマンドが子プロセスを残す、または SIGTERM を無視する。タイムアウトで zsh だけ止めても孫が生き残る。プロセスグループごと止め、失敗として記録する（Task 3 `timeoutKillsWholeProcessGroup`・`sigtermIgnoredIsKilled`）
4. Automation のコマンドが 64KB を超える出力を書く。パイプが詰まってタイムアウトまで固まる。出力はファイルへ直接書かせる（Task 3 `largeOutputDoesNotBlock`）
5. 会議ファイルのパスに日本語・空白・`#`・`&` が入る。「Obsidian で開く」の URL が壊れて別のノートを開く、または開かない（Task 10 `obsidianLinkEncodesEverythingButUnreserved`）

---

## 前提にした計画 01〜05 の API（Consumes。Lead が各計画と名前を揃える）

本計画はこれらを「あるもの」として使う。形が違えば Task 7 のアダプタ（`Presentation/LiveAdapters.swift`）だけを直せば済むように、画面と CLI は Task 7 の `*Port` にだけ依存させる。

| 計画 | 型・関数（前提にした形） |
|---|---|
| 01 | `struct AppPaths: Sendable { init(root: URL); static var standard: AppPaths; var root, recordings, transcripts, logs, settingsFile, automationsFile, socketFile: URL }` |
| 01 | `struct Settings: Codable, Sendable`（Task 15 の表のキー）、`actor SettingsStore { init(paths: AppPaths); func load() async throws -> Settings; func save(_ s: Settings) async throws }` |
| 01 | `actor ManifestStore { func all() async throws -> [Manifest]; func load(_ id: MeetingID) async throws -> Manifest }` |
| 01 | `actor PortableConfigStore { func outputFolderAvailable() async -> Bool; func loadDictionary() async throws -> DictionaryFile; func saveDictionary(_: DictionaryFile) async throws; func loadPrompt() async throws -> String; func savePrompt(_: String) async throws; func loadFrontmatterTemplate() async throws -> String; func saveFrontmatterTemplate(_: String) async throws }` |
| 01 | `struct DictionaryFile: Equatable, Sendable { var terms: [String]; var replacements: [Replacement]; var fillers: [String] }`、`struct Replacement: Equatable, Sendable { var from: String; var to: String }`、`struct Replacer: Sendable { init(_ rules: [Replacement]); func apply(_ text: String) -> String }` |
| 01 | `struct VaultScanner { init(outputFolder: URL); func scan() throws -> [VaultEntry] }`、`struct VaultEntry { var id: MeetingID; var title: String; var startedAt: Date; var durationMinutes: Int?; var status: String /* frontmatter の status */; var summaryFirstLine: String?; var fileURL: URL }` |
| 01 | `actor VaultWriter { func hasExternalChanges(_ id: MeetingID) async throws -> Bool; func rewriteMinutes(_ id: MeetingID, minutes: MinutesOutput, renameFile: Bool) async throws -> URL }` |
| 02 | `actor RecordingSession { func events() -> AsyncStream<RecordingEvent> }`（アプリに一つ。会議ごとに開始・停止。`events()` は呼ぶたびに新しい購読を返す。下の `snapshots()`・`updates()` も同じ）、`enum RecordingEvent: Sendable { case started(MeetingID), stopped(MeetingID, MeetingStatus), paused(TimelineTime), resumed(TimelineTime), bookmarked(Bookmark), silence(Track), diskLow(freeBytes: Int64), diskCritical(freeBytes: Int64) }` |
| 02 | `struct CrashRecovery { func interrupted() throws -> [Manifest]; func recover(_ id: MeetingID) async throws; func discard(_ id: MeetingID) throws }`、`actor AudioImporter { func importFile(_ url: URL, startedAt: Date) async throws -> MeetingID }` |
| 03 | `enum RecorderState { idle, countdown, recording, paused, grace }`、`struct RecorderSnapshot: Equatable, Sendable { var state: RecorderState; var meetingID: MeetingID?; var startedAt: Date?; var deviceName: String?; var deadline: Date? /* カウントダウン・猶予の満了 */; var isManual: Bool; var language: Language }` |
| 03 | `actor AutoRecordCoordinator { func current() -> RecorderSnapshot; func snapshots() -> AsyncStream<RecorderSnapshot>; func manualStart(language: Language?) async throws; func stop() async; func pause() async throws; func resume() async throws; func bookmark(note: String?) async throws -> Bookmark; func cancelCountdown() async; func setLanguage(_: Language) async; func handle(_ action: UserNoticeAction) async }` |
| 03 | `protocol UserNotifier: Sendable { func post(_ notice: UserNotice) async; func withdraw(id: String) async }`、`enum UserNotice` と `enum UserNoticeAction`（02・05・06 の分も含めて Task 12 の表の case を持つ） |
| 03 | `actor DeviceRegistry { func connected() async -> [ConnectedDevice]; func entries() async -> [DeviceEntry]; func register(uid: String) async throws; func ignore(uid: String) async throws; func remove(uid: String) async throws; func setMatchByModel(uid: String, _ on: Bool) async throws }`（`DeviceEntry` は表示名・方式・識別子・登録した Mac・`matchByModel`・`isIgnored`） |
| 04 | `struct EngineCatalog { func engines() -> [EngineDescriptor] }`、`EngineDescriptor { id: String; role: EngineRole /* .live / .batch */; displayName: String; isAvailable: Bool; models: [String] }`、`actor ModelManager { func models() -> [ModelInfo]; func download(_ name: String, progress: @Sendable @escaping (Double) -> Void) async throws; func delete(_ name: String) throws }`、`ModelInfo { name: String; sizeBytes: Int64; isDownloaded: Bool }`、`actor LiveFeed { func updates() -> AsyncStream<Utterance> }` |
| 05 | `actor PostProcessingQueue { init(stages: [any QueueStage], …); func snapshot() -> QueueSnapshot; func snapshots() -> AsyncStream<QueueSnapshot>; func enqueue(_ id: MeetingID) async throws; func regenerate(_ id: MeetingID) async throws; func retry(_ id: MeetingID) async throws }` |
| 05 | `struct QueueSnapshot: Equatable, Sendable { var jobs: [QueueJobSummary] }`、`QueueJobSummary { meetingID: MeetingID; stage: String; progress: Double?; state: QueueJobState }`、`enum QueueJobState { waiting, running, held(until: Date?), failed(String), done }` |
| 05 | `struct Job { var id: String /* 再生成ごとに新しい */; var meetingID: MeetingID; var outcome: MeetingStatus? /* minutesGenerated か transcriptOnly */; var vaultFile: URL?; var minutesFile: URL? }`、`StageContext`、`actor Retention { func deleteMeeting(_ id: MeetingID) async throws }`。議事録の構造化出力は `transcripts/<id>/minutes.json`、確定版は `final.json`、リアルタイム版は `live.json`（`Transcript` の JSON） |

## この計画で決めたこと

- グローバルショートカットは Carbon `RegisterEventHotKey`。アクセシビリティ（入力監視）許可が要らず、キーを前面アプリに漏らさない。`NSEvent.addGlobalMonitorForEvents` は許可が要り、キーを止められないので使わない。既定はブックマーク ⌃⌥B（要件書 §5.5）、録音開始・停止 ⌃⌥R、一時停止 ⌃⌥P［私の判断］
- 猶予中は「取り消す」を出さない。要件書 §15.1 は「カウントダウン中・猶予中のみ」と書くが、§5.9 の状態表が「「取り消す」ボタンは出さない」と明記しているので §5.9 に従う。猶予中は「機材が外れました。N 秒後に停止」と「停止」（即停止）を出す
- 「押すまで残る通知」は `Info.plist` の `NSUserNotificationAlertStyle = alert` で既定の表示スタイルを「通知パネル」にし、同じ操作をメニューバーにも置く（スタイルは利用者が変えられるため通知だけに頼らない）
- データ領域は環境変数 `AUTONOTE_DATA_DIR` で差し替えられる（アプリと CLI の両方。開発と E2E 用）。差し替え中の CLI はアプリを自動起動しない（`open -b` では環境変数を渡せないため）
- 初回注意書きはモーダルにせず小さなウィンドウで出す（E2E の起動直後の確認と CLI を止めないため）。クラッシュ復旧の確認だけ `NSAlert` を使う
- `LSUIElement` のアプリはメニューバーにファイルメニューを出せないので、要件書 §10 の「ファイルメニュー」はメインウィンドウのツールバーの「音声ファイルを取り込む…」で代える
- `AutoNoteCore` に `Automations/` と `Presentation/` のフォルダを足す（overview §2 に無い。Lead が overview に追記する）。`Package.swift` は変えない（Carbon・ServiceManagement・UserNotifications は自動リンク）

## ファイル構成

`Sources/AutoNoteCore/` に `Automations/`（Task 2〜4）と `Presentation/`（Task 7・10〜12・15）を新しく作り、`IPC/`（Task 1・5・6・8・9）を埋める。Port のフェイクは `Sources/AutoNoteTestSupport/FakePorts.swift`（Task 7）。`Sources/AutoNoteApp/` は画面と OS をつなぐコードだけ（Task 12〜15）。テストは `Tests/AutoNoteCoreTests/{IPC,Automations,Presentation}/`。各タスクの Files が正。

テストでソケットを作るときは `FileManager.temporaryDirectory`（`/var/folders/…` で長い）ではなく `/tmp/an-<8 桁の hex>/` を使う（Review Focus 1 のため）。

---

### Task 1: Bundle ID と証明書名の一本化（`scripts/config.sh`）

計画 00 最終レビュー M4。Bundle ID と証明書名が 3 本のスクリプトと Swift に散っているのを一か所にする。

**Files:**
- Create: `scripts/config.sh`
- Create: `Sources/AutoNoteCore/IPC/AppIdentity.swift`
- Modify: `scripts/build-app.sh`（`CERT_NAME` `BUNDLE_ID` の 2 行）、`scripts/e2e-check.sh`（同 2 行と確認項目の追加）、`scripts/make-dev-cert.sh`（`CERT_NAME` の 1 行）
- Test: `Tests/AutoNoteCoreTests/IPC/AppIdentityTests.swift`

**Interfaces:**
- Consumes: `AppPaths(root:)`、`AppPaths.standard`（計画 01）
- Produces: `public enum AppIdentity { public static let bundleID: String /* "com.yutaokoshi.autonote" */; public static let dataDirectoryEnvironmentKey: String /* "AUTONOTE_DATA_DIR" */; public static func paths(environment: [String: String]) -> AppPaths; public static func isDataDirectoryOverridden(_ environment: [String: String]) -> Bool }`。shell 変数 `AUTONOTE_BUNDLE_ID`、`AUTONOTE_CERT_NAME`

- [ ] **Step 1: 失敗するテストと E2E 項目を書く**
```swift
@Test func dataDirectoryOverride() {
    let p = AppIdentity.paths(environment: ["AUTONOTE_DATA_DIR": "/tmp/an-test"])
    #expect(p.root.path == "/tmp/an-test")
    #expect(AppIdentity.isDataDirectoryOverridden(["AUTONOTE_DATA_DIR": "/tmp/an-test"]))
}
@Test func defaultIsStandard() {
    #expect(AppIdentity.paths(environment: [:]).root == AppPaths.standard.root)
    #expect(AppIdentity.bundleID == "com.yutaokoshi.autonote")
}
```
`scripts/e2e-check.sh` に `check_identity_consistency`（項目名「0. Bundle ID の一本化」）を足し、CHECKS の先頭に置く。`scripts/config.sh` を source し、`Resources/Info.plist` の `CFBundleIdentifier`（PlistBuddy）と `AppIdentity.swift` の `bundleID`（sed）が `AUTONOTE_BUNDLE_ID` と一致すれば PASS。また `build-app.sh` と `make-dev-cert.sh` に `com.yutaokoshi.autonote` と `"AutoNote Dev"` の直書きが残っていないことを `grep -n` で確かめる（残っていれば FAIL。`e2e-check.sh` は検索語そのものを含むので対象にせず、Step 3 で目で直す）。
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AppIdentityTests; scripts/e2e-check.sh --quick` → Expected: テストは `cannot find 'AppIdentity' in scope` でビルド失敗。項目 0 は `scripts/config.sh` が無いので FAIL
- [ ] **Step 3: 実装する**
`scripts/config.sh` は次の 2 変数だけを持つ（source 専用。実行ビットは付けない）:
```bash
# Bundle ID と署名証明書名の唯一の定義。build-app.sh / e2e-check.sh / make-dev-cert.sh が source する
AUTONOTE_BUNDLE_ID="com.yutaokoshi.autonote"
AUTONOTE_CERT_NAME="AutoNote Dev"
```
3 本のスクリプトは自分の置き場所から `config.sh` を source し、`CERT_NAME="${AUTONOTE_CERT_NAME}"` `BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"` とする。`build-app.sh` は Info.plist を写した後、`CFBundleIdentifier` が `AUTONOTE_BUNDLE_ID` と違えばエラーで止まる（Info.plist の値は手で持つまま。違いを見逃さないための確認）。`AppIdentity.swift` を書く。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AppIdentityTests && scripts/e2e-check.sh` → Expected: PASS。E2E は項目 0 を含め 0 failed（項目 2〜5 も署名が変わらず PASS）
- [ ] **Step 5: コミット** — `git add scripts/config.sh scripts/build-app.sh scripts/e2e-check.sh scripts/make-dev-cert.sh Sources/AutoNoteCore/IPC/AppIdentity.swift Tests/AutoNoteCoreTests/IPC/AppIdentityTests.swift && git commit -m "chore: single source for bundle id and cert name (scripts/config.sh)"`

---

### Task 2: Automations の定義ファイル（`automations.json`）

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

### Task 3: `AutomationRunner`（実行・タイムアウト・ログ・二重実行防止）

**Files:**
- Create: `Sources/AutoNoteCore/Automations/AutomationContext.swift`, `AutomationRunRecord.swift`, `ProcessGroupSpawner.swift`, `AutomationRunner.swift`
- Test: `Tests/AutoNoteCoreTests/Automations/AutomationRunnerTests.swift`

**Interfaces:**
- Consumes: `AutomationDefinition`, `AutomationTrigger`（Task 2）、`MeetingID`（計画 01）
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

### Task 4: `AutomationsStage` と録音のきっかけ

**Files:**
- Create: `Sources/AutoNoteCore/Automations/AutomationDispatcher.swift`, `AutomationsStage.swift`, `RecordingAutomationTrigger.swift`
- Test: `Tests/AutoNoteCoreTests/Automations/AutomationDispatcherTests.swift`

**Interfaces:**
- Consumes: `AutomationsFile`（Task 2）、`AutomationRunner`, `AutomationContext`（Task 3）、`QueueStage`, `Job`, `StageContext`（計画 05）、`ManifestStore`, `Manifest`（計画 01）、`RecordingEvent`（計画 02）、`UserNotifier`, `UserNotice.automationFailed`（計画 03）
- Produces:
  - `public struct AutomationDispatcher: Sendable { public init(file: AutomationsFile, runner: AutomationRunner, notifier: (any UserNotifier)?); public func dispatch(_ trigger: AutomationTrigger, context: AutomationContext, dedupeKey: String?) async -> [AutomationRunRecord]; public func runOne(name: String, context: AutomationContext) async throws -> AutomationRunRecord /* 見つからなければ AppCommandError.notFound */ }`
  - `public enum AutomationContextBuilder { public static func make(event: AutomationTrigger, manifest: Manifest, file: URL?, minutesJSON: URL?, timeZone: TimeZone = .current) -> AutomationContext }`
  - `public struct AutomationsStage: QueueStage { public let name = "automations"; public init(dispatcher: AutomationDispatcher, manifests: ManifestStore); public static func trigger(for outcome: MeetingStatus?) -> AutomationTrigger?; public func run(_ job: inout Job, context: StageContext) async throws }`
  - `public actor RecordingAutomationTrigger { public init(dispatcher: AutomationDispatcher, manifests: ManifestStore); public func consume(_ events: AsyncStream<RecordingEvent>) async }`
- `runOne` は `AppCommandError`（Task 7）を使うので、本タスクでは作らず Task 7 の Step 3 で同じファイルに足す

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func triggerMapping() {
    #expect(AutomationsStage.trigger(for: .minutesGenerated) == .minutesGenerated)
    #expect(AutomationsStage.trigger(for: .transcriptOnly) == .transcriptOnly)
    #expect(AutomationsStage.trigger(for: .failed) == nil && AutomationsStage.trigger(for: nil) == nil)
}
@Test func runsOnlyMatchingRunnableInFileOrder() async  // A(minutes) B(minutes, enabled false) C(transcript_only) D(minutes) → 記録の name == ["A", "D"]
@Test func failureDoesNotThrowAndNotifies() async       // "exit 1" の定義 → 記録 1 件 succeeded false、FakeUserNotifier.posted == [.automationFailed(name: "A", meetingID: id)]
@Test func permissionDisabledRunsNothing() async        // 0664 のファイル → 記録 0 件
@Test func contextFromManifest()   // startedAt 2026-10-24T05:00:00Z、title nil、timeZone Asia/Tokyo → title "", date "2026-10-24", start "14:00", file nil
@Test func recordingEventsFireStartedAndStoppedOnce() async   // [.started(id), .bookmarked(b), .stopped(id, .recorded), .stopped(id, .recorded)] → recording_started 1 回、recording_stopped 1 回
```
`FakeUserNotifier` は計画 03 が TestSupport に置くもの（無ければ本タスクで `Sources/AutoNoteTestSupport/FakeUserNotifier.swift` に `posted: [UserNotice]` を持つ actor として置く）。
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AutomationDispatcherTests` → Expected: `cannot find 'AutomationDispatcher' in scope` でビルド失敗
- [ ] **Step 3: 実装する**

- `dispatch` は毎回 `file.load()` で読み直す（外で編集されても次の実行に効く）。`isRunnable && on == trigger` の件を配列順に `runner.run` し、`dedupeKey` は `"<dedupeKey>|<name>"`。失敗した件ごとに `notifier?.post(.automationFailed(name:meetingID:))`
- `AutomationsStage.run`: `trigger(for: job.outcome)` が nil なら何もしない。manifest を読み、`dispatch(trigger, context: make(event:manifest:file: job.vaultFile, minutesJSON: trigger == .minutesGenerated ? job.minutesFile : nil), dedupeKey: "job:\(job.id)")`。Automation の失敗では throw しない（要件書 §14.5「議事録の成否に影響しない」）。再生成は計画 05 が新しい `job.id` を作るので `minutes_generated` が改めて発火する（§14.5）
- `RecordingAutomationTrigger.consume`: `.started` → `recording_started`、`.stopped` → `recording_stopped`。`file` と `minutesJSON` は nil。dedupeKey は `"rec:<id>:<event>"`
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AutomationDispatcherTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Automations Sources/AutoNoteTestSupport Tests/AutoNoteCoreTests/Automations && git commit -m "feat: automations queue stage and recording event triggers"`

---

### Task 5: ソケットのプロトコル（JSON 行）

**Files:**
- Create: `Sources/AutoNoteCore/IPC/IPCProtocol.swift`, `Sources/AutoNoteCore/IPC/WireTypes.swift`, `Sources/AutoNoteCore/IPC/LineCodec.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/IPCProtocolTests.swift`

**Interfaces:**
- Consumes: `Language`, `Bookmark`, `MeetingID`（計画 01）、`AutomationTrigger`, `AutomationRunRecord`（Task 2・3）
- Produces:
  - `public enum IPCCommand: String, Codable, Sendable, CaseIterable { case start, stop, pause, resume, bookmark, status, list, latest, `import`, regenerate, automationsList = "automations.list", automationsRun = "automations.run" }`（要件書 §16 の表と 1 対 1）
  - `public struct IPCArgs: Codable, Equatable, Sendable { public var lang: Language?; public var note: String?; public var since: String?; public var open: Bool?; public var file: String?; public var meetingID: String?; public var name: String?; public init(lang: Language? = nil, note: String? = nil, since: String? = nil, open: Bool? = nil, file: String? = nil, meetingID: String? = nil, name: String? = nil) }`
  - `public struct IPCRequest: Codable, Equatable, Sendable { public var cmd: IPCCommand; public var args: IPCArgs; public var id: Int }`
  - `public enum IPCErrorCode: String, Codable, Sendable { case notRecording = "not_recording", alreadyRecording = "already_recording", notFound = "not_found", invalidArgs = "invalid_args", unknownCommand = "unknown_command", badRequest = "bad_request", failed }`
  - `public struct IPCError: Codable, Equatable, Sendable, Error { public var code: IPCErrorCode; public var message: String }`
  - `public struct IPCResult: Codable, Equatable, Sendable { public var status: StatusResult?; public var meetings: [MeetingRow]?; public var path: String?; public var meetingID: String?; public var bookmark: Bookmark?; public var automations: [AutomationSummary]?; public var run: AutomationRunRecord? }`
  - `public struct IPCResponse: Codable, Equatable, Sendable { public var id: Int?; public var ok: Bool; public var result: IPCResult?; public var error: IPCError?; public static func success(_ id: Int, _ r: IPCResult) -> IPCResponse; public static func failure(_ id: Int?, _ e: IPCError) -> IPCResponse }`
  - `WireTypes.swift`: `public struct StatusResult: Codable, Equatable, Sendable { public var recorder: RecorderStatusDTO; public var queue: [QueueItemDTO]; public var outputFolderAvailable: Bool }`、`public struct RecorderStatusDTO { state: String /* idle countdown recording paused grace */; meetingID: String?; elapsedSeconds: Int?; device: String?; secondsRemaining: Int?; language: Language? }`、`public struct QueueItemDTO { meetingID: String; stage: String; state: String /* waiting running held failed done */; progress: Double?; label: String; message: String? }`、`public enum MeetingRowState: String, Codable, Sendable { case recording, recorded, processing, minutesGenerated = "minutes_generated", transcriptOnly = "transcript_only", failed, tooShort = "too_short" }`、`public struct MeetingRow: Codable, Equatable, Sendable, Identifiable { id: String; title: String; startedAt: Date; durationMinutes: Int?; state: MeetingRowState; progressLabel: String?; filePath: String?; silenceWarning: Bool; summaryFirstLine: String? }`、`public struct AutomationSummary { name: String; on: AutomationTrigger; enabled: Bool; isRunnable: Bool; problem: String? }`（すべて `Codable, Equatable, Sendable` で、`public var` の各項目に既定値（nil・空配列・false）つきの `public init` を持つ）、`public enum StageLabel { public static func text(stage: String, progress: Double?) -> String }`
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

### Task 6: `SocketServer` と `SocketClient`

**Files:**
- Create: `Sources/AutoNoteCore/IPC/UnixSocket.swift`, `Sources/AutoNoteCore/IPC/SocketServer.swift`, `Sources/AutoNoteCore/IPC/SocketClient.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/SocketTests.swift`

**Interfaces:**
- Consumes: `IPCRequest`, `IPCResponse`, `IPCCodec`, `LineBuffer`, `IPCCommand`, `IPCArgs`（Task 5）、`AppIdentity.bundleID`（Task 1）
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

### Task 7: サービスの窓口（Port）、アダプタ、会議一覧の組み立て

画面と CLI が計画 01〜05 の具体型に直接触らないよう、窓口を protocol で切る。フェイクで AppModel と CommandRouter をテストできるようにする。

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/Ports.swift`, `Sources/AutoNoteCore/Presentation/LiveAdapters.swift`, `Sources/AutoNoteCore/Presentation/MeetingListBuilder.swift`
- Create: `Sources/AutoNoteTestSupport/FakePorts.swift`
- Modify: `Sources/AutoNoteCore/Automations/AutomationDispatcher.swift`（`runOne` を足す）
- Test: `Tests/AutoNoteCoreTests/Presentation/MeetingListBuilderTests.swift`, `Tests/AutoNoteCoreTests/Presentation/RecorderCommandRulesTests.swift`

**Interfaces:**
- Consumes: 冒頭の「前提にした API」の表すべて、`MeetingRow`, `MeetingRowState`, `StageLabel`, `AutomationSummary`（Task 5）、`AutomationDispatcher`, `AutomationRunner`（Task 3・4）
- Produces:
  - `public enum AppCommandError: Error, Equatable, Sendable { case notRecording, alreadyRecording, notFound(String), invalid(String), failed(String) }`
  - `public enum RecorderCommand: Sendable { case start, stop, pause, resume, bookmark }`、`public enum RecorderCommandRules { public static func check(_ c: RecorderCommand, state: RecorderState) throws(AppCommandError) }`
  - `public protocol RecorderPort: Sendable { func current() async -> RecorderSnapshot; func snapshots() async -> AsyncStream<RecorderSnapshot>; func start(language: Language?) async throws; func stop() async throws; func pause() async throws; func resume() async throws; func bookmark(note: String?) async throws -> Bookmark; func cancelCountdown() async; func setLanguage(_ l: Language) async; func handleNotice(_ action: UserNoticeAction) async }`
  - `public protocol RecordingEventsPort: Sendable { func events() async -> AsyncStream<RecordingEvent> }`
  - `public protocol QueuePort: Sendable { func snapshot() async -> QueueSnapshot; func snapshots() async -> AsyncStream<QueueSnapshot>; func enqueue(_ id: MeetingID) async throws; func regenerate(_ id: MeetingID) async throws; func retry(_ id: MeetingID) async throws }`
  - `public protocol MeetingsPort: Sendable { func rows() async throws -> [MeetingRow]; func latestMinutesFile() async throws -> URL?; func manifest(_ id: MeetingID) async throws -> Manifest; func minutes(_ id: MeetingID) async throws -> MinutesOutput?; func transcript(_ id: MeetingID, kind: TranscriptKind) async throws -> Transcript?; func saveMinutes(_ id: MeetingID, _ m: MinutesOutput, renameFile: Bool) async throws -> URL; func hasExternalChanges(_ id: MeetingID) async throws -> Bool; func importAudio(_ file: URL, startedAt: Date?) async throws -> MeetingID; func delete(_ id: MeetingID) async throws; func interrupted() async throws -> [Manifest]; func recover(_ id: MeetingID) async throws; func discard(_ id: MeetingID) async throws }`、`public enum TranscriptKind: String, Sendable { case live, final }`
  - `public protocol AutomationsPort: Sendable { func summaries() async -> ([AutomationSummary], warnings: [String]); func run(name: String, meetingID: MeetingID) async throws -> AutomationRunRecord; func recentRuns(limit: Int) async -> [AutomationRunRecord]; func records() async -> AsyncStream<AutomationRunRecord> }`
  - `public protocol LiveTranscriptPort: Sendable { func updates() async -> AsyncStream<Utterance> }`、`public protocol OutputFolderPort: Sendable { func isAvailable() async -> Bool }`、`public protocol FileOpener: Sendable { func open(_ file: URL) async }`
  - `public struct AppPorts: Sendable { public var recorder: any RecorderPort; public var events: any RecordingEventsPort; public var queue: any QueuePort; public var meetings: any MeetingsPort; public var automations: any AutomationsPort; public var live: any LiveTranscriptPort; public var outputFolder: any OutputFolderPort; public var opener: any FileOpener; public init(…) }`
  - `public enum MeetingListBuilder { public static func build(vault: [VaultEntry], manifests: [Manifest], queue: QueueSnapshot) -> [MeetingRow]; public static func filter(_ rows: [MeetingRow], since: String, calendar: Calendar) throws(AppCommandError) -> [MeetingRow] }`
  - アダプタ（`LiveAdapters.swift`）: `CoordinatorRecorderPort(coordinator:)`、`SessionEventsPort(session:)`、`QueueAdapter(queue:)`、`MeetingsAdapter(paths:manifests:vaultScanner:vaultWriter:importer:retention:crashRecovery:queue:)`、`AutomationsAdapter(file:dispatcher:runner:manifests:)`、`LiveFeedPort(feed:)`、`PortableOutputFolderPort(store:)`
  - フェイク（`FakePorts.swift`）: `FakeRecorderPort`、`FakeRecordingEventsPort`、`FakeQueuePort`、`FakeMeetingsPort`、`FakeAutomationsPort`、`FakeLiveTranscriptPort`、`FakeOutputFolderPort`、`FakeFileOpener`。それぞれ actor で、呼ばれた操作を `calls: [String]` に積み、流す値は `send(_:)` で入れられ、`nextError: AppCommandError?` を一度だけ投げる。`static func make() -> AppPorts` 相当の `FakePorts` 構造体でまとめて作れる

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test(arguments: [(RecorderCommand.bookmark, RecorderState.idle), (.bookmark, .countdown), (.stop, .idle), (.stop, .countdown), (.pause, .idle), (.resume, .idle)])
func rejectsWhenNotRecording(c: RecorderCommand, s: RecorderState) {
    #expect(throws: AppCommandError.notRecording) { try RecorderCommandRules.check(c, state: s) }
}
@Test(arguments: [RecorderState.recording, .paused, .grace]) func startWhileRecordingIsAlready(s: RecorderState) {
    #expect(throws: AppCommandError.alreadyRecording) { try RecorderCommandRules.check(.start, state: s) }
}
@Test(arguments: [RecorderState.recording, .paused, .grace]) func bookmarkAllowed(s: RecorderState) throws { try RecorderCommandRules.check(.bookmark, state: s) }
@Test func pauseResumeWrongState() {
    #expect(throws: AppCommandError.invalid("すでに一時停止中です")) { try RecorderCommandRules.check(.pause, state: .paused) }
    #expect(throws: AppCommandError.invalid("一時停止中ではありません")) { try RecorderCommandRules.check(.resume, state: .recording) }
    #expect(throws: AppCommandError.invalid("機材が外れているあいだは一時停止できません")) { try RecorderCommandRules.check(.pause, state: .grace) }
}
@Test func startFromCountdownIsAllowed() throws { try RecorderCommandRules.check(.start, state: .countdown) }  // §5.9 手動開始でカウントダウン破棄

@Test func vaultOnlyEntryAppears()          // manifest が保持期限で消えた会議 → state .minutesGenerated、filePath あり
@Test func manifestOnlyRecordingAppears()   // Vault に無い録音中 → state .recording、title == "（無題）"
@Test func vaultTitleWins()                 // 両方ある → Vault の title
@Test func runningJobOverridesState()       // queue に running の transcribe 0.42 → state .processing、progressLabel == "文字起こし中 42%"
@Test func failedJobShowsTranscriptOnly()   // Vault status transcript_only → .transcriptOnly
@Test func tooShortAndSilenceWarning()      // manifest status .tooShort → .tooShort、silenceWarning true が引き継がれる
@Test func newestFirst()
@Test func sinceFilter() throws             // "2026-10-01" より前は落ちる。"10/01" → throws .invalid("日付は YYYY-MM-DD で指定してください: 10/01")
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter "MeetingListBuilderTests|RecorderCommandRulesTests"` → Expected: `cannot find 'MeetingListBuilder' in scope` でビルド失敗
- [ ] **Step 3: 実装する**

- `RecorderCommandRules`: start は `recording/paused/grace` で `.alreadyRecording`。stop は `idle/countdown` で `.notRecording`。pause は `recording` だけ、resume は `paused` だけ許す（`idle/countdown` は `.notRecording`、それ以外はテストの `.invalid` 文言）。bookmark は `recording/paused/grace`
- アダプタは操作の前に `RecorderCommandRules.check` を呼び、計画 01〜05 の投げるエラーは `.failed(error.localizedDescription)` に包む。`MeetingsAdapter.rows()` は `outputFolderAvailable` でなければ Vault を読まず manifest だけで組む。`latestMinutesFile()` は `rows()` のうち `filePath` がある最新。`minutes(_:)` は `transcripts/<id>/minutes.json`、`transcript(_:kind:)` は `transcripts/<id>/<kind>.json` を読み、無ければ nil
- `AutomationDispatcher.runOne(name:context:)` を足す（`isRunnable` でなければ `.invalid(problem ?? "無効になっています")`、無ければ `.notFound("Automation が見つかりません: <name>")`。`dedupeKey` は nil＝手動）。`AutomationsAdapter.run` は manifest と `minutes.json`・Vault ファイルの有無から `AutomationContextBuilder.make(event: 定義の on, …)` を作って `runOne` を呼ぶ
- Vault の status 文字列 → `MeetingRowState`: `minutes_generated` `transcript_only` `failed` はそのまま、それ以外は `.minutesGenerated`
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter "MeetingListBuilderTests|RecorderCommandRulesTests"` → Expected: PASS。続けて `swift build` が通る（アダプタが計画 01〜05 の型と合う）
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation Sources/AutoNoteCore/Automations Sources/AutoNoteTestSupport Tests/AutoNoteCoreTests/Presentation && git commit -m "feat: service ports, adapters and meeting list builder"`

---

### Task 8: `CommandRouter`（ソケットの要求をサービスへ）

**Files:**
- Create: `Sources/AutoNoteCore/IPC/CommandRouter.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/CommandRouterTests.swift`

**Interfaces:**
- Consumes: `IPCHandler`（Task 6）、`IPCRequest/IPCResponse/IPCResult/StatusResult/...`（Task 5）、`AppPorts`, `AppCommandError`, `MeetingListBuilder.filter`, `FakePorts`（Task 7）
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
`handle` は `cmd` で分岐し、各 Port を呼んで `IPCResult` の該当項目だけを埋める。`status` は `recorder.current()`・`queue.snapshot()`・`outputFolder.isAvailable()` から組み、`QueueItemDTO.label` は `StageLabel.text`。`regenerate` と `automations.run` の `meetingID` は `MeetingID(rawValue:)` で包む。`import` の `startedAt` は nil（ファイルの作成日時が既定。§10）。MainActor には乗らない。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter CommandRouterTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/IPC/CommandRouter.swift Tests/AutoNoteCoreTests/IPC/CommandRouterTests.swift && git commit -m "feat: route IPC commands to app services"`

---

### Task 9: CLI `autonote`（§16 の全コマンド、`--json`、終了コード、使い方）

**Files:**
- Create: `Sources/AutoNoteCore/IPC/CLIInvocation.swift`, `Sources/AutoNoteCore/IPC/CLIRenderer.swift`
- Modify: `Sources/autonote/main.swift`
- Test: `Tests/AutoNoteCoreTests/IPC/CLITests.swift`

**Interfaces:**
- Consumes: `IPCCommand`, `IPCArgs`, `IPCResponse`（Task 5）、`SocketClient`, `SocketClientError`, `OpenBundleLauncher`（Task 6）、`AppIdentity`（Task 1）
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

- `CLIParser`: `--json` はどの位置でも取り除いてから解釈する。引数の数が合わない・知らないオプションは `CLIUsageError`。`--since` の書式はアプリ側（Task 8）で検める。`import` は `cwd` に対して絶対パスにし `standardizedFileURL` で正規化
- `CLIRenderer`: 人向けは上のテストの書式。`latest` は `path` だけ。`import`・`regenerate` は「受け付けました: <id>」。`automations list` は「<name>  <on>  有効|無効（problem）」。`automations run` は「終了コード <n>（<秒> 秒）ログ: <logDirectory>」、タイムアウトは「タイムアウトしました（<秒> 秒）ログ: …」で終了コード 1。`--json` の成功は `result` だけを 1 行で出す
- `main.swift`: `--version` は今のまま。`dev` は計画 01〜05 が足した分岐へそのまま渡す（消さない）。それ以外は `CLIParser` → `SocketClient(socketURL: paths.socketFile, launcher: AppIdentity.isDataDirectoryOverridden(env) ? nil : OpenBundleLauncher())` → `CLIRenderer` → stdout/stderr に書いて `exit(exitCode)`。引数なしは使い方を stderr に出して終了コード 1（E2E 項目 6 が `usage:` と 1 を見る）
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter CLITests && swift build --product autonote && $(swift build --show-bin-path)/autonote; echo "exit=$?"` → Expected: テスト PASS。最後のコマンドは stderr に `usage: autonote start …` を出し `exit=1`
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/IPC Sources/autonote/main.swift Tests/AutoNoteCoreTests/IPC/CLITests.swift && git commit -m "feat: autonote user commands over the socket"`

---

### Task 10: 表示規則（メニューバー、リアルタイム文字起こし、終了判定、Obsidian リンク、ショートカット）

画面から切り離せる判断をすべて純粋な関数・値型にしてテストする。

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/MenuBarPresentation.swift`, `LiveTranscriptBuffer.swift`, `QuitPolicy.swift`, `ObsidianLink.swift`, `KeyCombo.swift`
- Modify: `Sources/AutoNoteCore/Storage/Settings.swift`（`shortcuts` と `consentNoticeShown` を `decodeIfPresent` で足す。計画 01 が同名の項目を既に持つなら型だけ合わせる）
- Test: `Tests/AutoNoteCoreTests/Presentation/MenuBarPresentationTests.swift`, `LiveTranscriptBufferTests.swift`, `QuitPolicyTests.swift`, `ObsidianLinkTests.swift`, `KeyComboTests.swift`

**Interfaces:**
- Consumes: `RecorderSnapshot`, `RecorderState`（計画 03）、`QueueSnapshot`（計画 05）、`Utterance`, `Bookmark`, `TimelineTime`, `Replacer`, `Settings`（計画 01）、`MeetingRow`, `StageLabel`, `AutomationRunRecord`（Task 3・5）
- Produces:
  - `public enum MenuItem: Equatable, Sendable { case status(String), startRecording, stop, pause, resume, bookmark, cancelCountdown, language(current: Language), openWindow, openLatestMinutes(enabled: Bool), minutesMissing(MeetingID, label: String), automationFailed(name: String, meetingID: MeetingID), settings, quit }`
  - `public struct MenuBarPresentation: Equatable, Sendable { public var symbol: String; public var title: String?; public var items: [MenuItem]; public static func make(recorder: RecorderSnapshot, queue: QueueSnapshot, outputFolderAvailable: Bool, latestMinutesAvailable: Bool, rows: [MeetingRow], automationFailures: [AutomationRunRecord], now: Date) -> MenuBarPresentation }`
  - `public enum LiveLine: Equatable, Sendable, Identifiable { case utterance(Utterance), bookmark(Bookmark), pause(TimelineTime) }`（`pause` の表示文字列は `LiveLine.pauseText == "── 一時停止 ──"`）
  - `public struct LiveTranscriptBuffer: Equatable, Sendable { public init(replacer: Replacer? = nil); public mutating func apply(_ u: Utterance); public mutating func add(_ b: Bookmark); public mutating func addPause(at: TimelineTime); public mutating func reset(); public var lines: [LiveLine] { get } }`
  - `public enum QuitReason: Sendable { case user, powerOff }`、`public enum QuitDecision: Equatable, Sendable { case terminateNow, cancelCountdownThenTerminate, confirm, stopThenTerminate }`、`public enum QuitPolicy { public static let confirmMessage = "録音中です。停止して終了しますか？"; public static func decide(_ s: RecorderState, reason: QuitReason) -> QuitDecision }`
  - `public enum ObsidianLink { public static func url(for file: URL) -> URL }`
  - `public struct KeyCombo: Codable, Equatable, Hashable, Sendable { public var keyCode: UInt32; public var modifiers: UInt32 /* Carbon: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096 */; public var display: String { get }; public func validate() throws(AppCommandError) }`
  - `public enum ShortcutAction: String, Codable, Sendable, CaseIterable { case bookmark, toggleRecording, togglePause }`
  - `public struct ShortcutBindings: Codable, Equatable, Sendable { public var bookmark: KeyCombo?; public var toggleRecording: KeyCombo?; public var togglePause: KeyCombo?; public static let `default`: ShortcutBindings; public func combo(for: ShortcutAction) -> KeyCombo?; public func duplicates() -> [ShortcutAction] }`
  - `Settings` に `public var shortcuts: ShortcutBindings`（既定 `.default`）、`public var consentNoticeShown: Bool`（既定 false）

- [ ] **Step 1: 失敗するテストを書く**
```swift
// MenuBarPresentationTests
@Test func idle() {
    let p = make(state: .idle)
    #expect(p.symbol == "waveform" && p.title == nil)     // E2E 7b はアイドル時の項目名 waveform を見る
    #expect(p.items.contains(.startRecording) && !p.items.contains(.stop) && !p.items.contains(.cancelCountdown) && p.items.suffix(2) == [.settings, .quit])
}
@Test func countdown()            // deadline now+3、device "Jabra" → .status("Jabraが接続されました。3 秒後に録音を始めます")、.cancelCountdown と .startRecording あり
@Test func recording()            // startedAt now-754 → symbol "record.circle"、title "12:34"、.stop .pause .bookmark .language(current: .ja) あり
@Test func recordingOverAnHour()  // 3754 秒 → title "1:02:34"
@Test func paused()               // symbol "pause.circle"、.resume あり、.pause なし、status "一時停止中"
@Test func graceHasNoCancel() {   // 要件書 §5.9
    let p = make(state: .grace, startedAt: now - 100, deadline: now + 12)
    #expect(p.items.contains(.status("機材が外れました。12 秒後に停止")) && !p.items.contains(.cancelCountdown) && p.items.contains(.stop))
}
@Test func processing()           // idle + running transcribe 0.42 → symbol "hourglass"、.status("文字起こし中 42%")
@Test func outputFolderMissing()  // → .status("出力フォルダが見つかりません")
@Test func failuresListed()       // transcript_only の行 → .minutesMissing(id, label: "議事録 未生成: 10/24 14:00")、失敗記録 → .automationFailed(name: "Slack に要約を投稿", …)
// LiveTranscriptBufferTests
@Test func partialReplacedBySameStartAndSpeaker()   // 部分 "こんに" → 部分 "こんにちは" → 確定 "こんにちは。" で lines 1 件、isFinal true
@Test func linesSortedByTimeWithMarkers()           // 発話 10s, 30s、ブックマーク 20s、一時停止 25s → [10s, bm20, pause25, 30s]
@Test func sameStartDifferentSpeakersKeptApart()    // 自分と相手が同じ 10s → 2 件（自分が先）
@Test func replacerAppliedForDisplay()              // Replacer([オートノート => AutoNote]) → 表示テキスト "AutoNote"
@Test func resetClears()
// QuitPolicyTests
@Test func decisions() {
    #expect(QuitPolicy.decide(.idle, reason: .user) == .terminateNow)
    #expect(QuitPolicy.decide(.countdown, reason: .user) == .cancelCountdownThenTerminate)
    for s in [RecorderState.recording, .paused, .grace] {
        #expect(QuitPolicy.decide(s, reason: .user) == .confirm)
        #expect(QuitPolicy.decide(s, reason: .powerOff) == .stopThenTerminate)
    }
}
// ObsidianLinkTests
@Test func obsidianLinkEncodesEverythingButUnreserved() {
    let u = ObsidianLink.url(for: URL(filePath: "/Users/a/Vault/Meetings/2026/2026-10-24_1400_定例 #1 & A.md"))
    #expect(u.absoluteString == "obsidian://open?path=%2FUsers%2Fa%2FVault%2FMeetings%2F2026%2F2026-10-24_1400_%E5%AE%9A%E4%BE%8B%20%231%20%26%20A.md")
}
// KeyComboTests
@Test func defaults()              // bookmark == KeyCombo(keyCode: 11, modifiers: 6144) で display "⌃⌥B"（§5.5）、toggleRecording は keyCode 15 "⌃⌥R"、togglePause は keyCode 35 "⌃⌥P"
@Test func displayOrder()          // control+option+shift+command と keyCode 0 → "⌃⌥⇧⌘A"
@Test func validateRejects()       // modifiers 0 → throws .invalid("⌃ ⌥ ⌘ のどれかを含めてください")、shiftKey だけも同じ
@Test func duplicatesDetected()    // bookmark と togglePause が同じ → [.bookmark, .togglePause]
@Test func settingsWithoutShortcutsDecodesDefaults() throws  // "{}" を Settings として decode → shortcuts == .default、consentNoticeShown == false
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter "MenuBarPresentationTests|LiveTranscriptBufferTests|QuitPolicyTests|ObsidianLinkTests|KeyComboTests"` → Expected: `cannot find 'MenuBarPresentation' in scope` などでビルド失敗
- [ ] **Step 3: 実装する**

- `MenuBarPresentation.make` の項目の並び: 状態行（あれば）→ 録音操作（idle/countdown: 録音開始、recording: 停止・一時停止・ブックマーク、paused: 停止・再開・ブックマーク、grace: 停止・ブックマーク）→ countdown のときだけ取り消す → 録音中なら言語 → 待ち行列の状態行（running の各件 `StageLabel.text`）→ 出力フォルダなし → 議事録 未生成・Automation 失敗の各件 → ウィンドウを開く → 最新の議事録を開く → 設定 → 終了。記号は idle かつ running の件があれば `hourglass`、idle/countdown は `waveform`、recording/grace は `record.circle`、paused は `pause.circle`。`title` は recording/paused/grace だけ（経過時間。一時停止中も進む §5.4）。残り秒は `ceil(deadline - now)`、0 未満は 0
- `LiveTranscriptBuffer`: 発話は `(speaker, start)` を鍵に置き換える。並びは時刻順、同時刻は 発話（自分 → 相手 → 不明）→ ブックマーク → 一時停止
- `ObsidianLink`: `path` の値は ASCII の英数字と `-._~` だけを残して百分率符号化する。`CharacterSet.alphanumerics` は漢字も含むので使わない（自前の ASCII 集合を作る）
- `KeyCombo.display`: 記号は ⌃⌥⇧⌘ の順、キーは ANSI の英字・数字・F1〜F12 を表で引き、それ以外は `Key<code>`
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter "MenuBarPresentationTests|LiveTranscriptBufferTests|QuitPolicyTests|ObsidianLinkTests|KeyComboTests"` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation Sources/AutoNoteCore/Storage/Settings.swift Tests/AutoNoteCoreTests/Presentation && git commit -m "feat: menu bar, live transcript, quit and shortcut presentation rules"`

---

### Task 11: `AppModel`（各サービスの状態を UI 用に集約）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/AppModel.swift`
- Test: `Tests/AutoNoteCoreTests/Presentation/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppPorts` と各フェイク（Task 7）、`MenuBarPresentation`, `LiveTranscriptBuffer`, `QuitPolicy`（Task 10）、`CommandRouter.ipcError`（Task 8。エラー文言を揃えるため）
- Produces:
  - `public enum UserAction: Equatable, Sendable { case start, stop, pause, resume, bookmark(String?), cancelCountdown, setLanguage(Language), regenerate(MeetingID), retry(MeetingID), transcribeTooShort(MeetingID), discardTooShort(MeetingID), delete(MeetingID), rerunAutomation(name: String, meetingID: MeetingID), importAudio(URL, startedAt: Date?), recoverInterrupted(MeetingID), discardInterrupted(MeetingID), openLatestMinutes, open(MeetingID), notice(UserNoticeAction), toggleRecording, togglePause }`
  - `@MainActor @Observable public final class AppModel { public init(ports: AppPorts, replacer: Replacer? = nil, now: @escaping @Sendable () -> Date = { Date() }); public private(set) var recorder: RecorderSnapshot; public private(set) var queue: QueueSnapshot; public private(set) var meetings: [MeetingRow]; public private(set) var live: LiveTranscriptBuffer; public private(set) var outputFolderAvailable: Bool; public private(set) var automationFailures: [AutomationRunRecord]; public private(set) var diskWarning: String?; public private(set) var lastError: String?; public var selectedMeetingID: MeetingID?; public func run() async; public func refresh() async; public func menuBar(now: Date) -> MenuBarPresentation; public func perform(_ a: UserAction) async; public func quitDecision(reason: QuitReason) -> QuitDecision }`

- [ ] **Step 1: 失敗するテストを書く**
すべて `@MainActor`。`run()` は `Task` で起こし、フェイクに値を流してから `await model.settle()`（テスト用に `internal func settle() async` を置き、購読が流れ終わるのを待つ）で確かめる。
```swift
@Test func recorderSnapshotDrivesMenuBar() async   // recording の snapshot を send → settle → menuBar(now:).symbol == "record.circle"
@Test func liveUtterancesAccumulate()           // 部分 → 確定で live.lines 1 件
@Test func bookmarkAndPauseEventsAddMarkers()   // RecordingEvent .bookmarked / .paused → LiveLine.bookmark / .pause
@Test func newMeetingResetsLive()               // meetingID が変わったら live を空にする
@Test func queueChangeRefreshesMeetings()       // QueueSnapshot が変わるたび FakeMeetingsPort.rows の呼び出しが増える
@Test func actionsForwarded()                   // perform(.bookmark("x")) → recorder.calls == ["bookmark(x)"]、.toggleRecording は idle → start、recording → stop
@Test func errorsSurfaceWithRouterWording()     // nextError .notRecording → lastError == "録音中ではありません"
@Test func automationFailureCollectedAndCleared() // 失敗記録 → automationFailures 1 件。同名・同会議の成功記録で消える
@Test func diskWarnings()   // .diskLow → diskWarning == "ディスクの空きが 1GB を切りました"、.diskCritical → "ディスクの空きが 500MB を切ったため録音を停止しました"
@Test func outputFolderPolled()                 // FakeOutputFolderPort false → refresh 後 outputFolderAvailable == false
@Test func noticeActionsRouted()                // .notice(.cancelCountdown) → recorder.cancelCountdown、.notice(.regenerate(id)) → queue.regenerate(id)、機材系は recorder.handleNotice
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AppModelTests` → Expected: `cannot find 'AppModel' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
`run()` は `withTaskGroup` で recorder・events・queue・live・automations の各ストリームを購読し、30 秒ごとに `outputFolder.isAvailable()` と `meetings.rows()` を読み直す［私の判断］。`perform` は Port を呼び、失敗は `CommandRouter.ipcError(e).message` を `lastError` に入れる。`UserNoticeAction` のうち `.openMeeting(id)` は `selectedMeetingID` を変えるだけ（ウィンドウを開くのは App 側）。`.toggleRecording` と `.togglePause` はショートカット用で、今の状態で開始・停止・一時停止・再開を選ぶ。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AppModelTests` → Expected: PASS
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation/AppModel.swift Tests/AutoNoteCoreTests/Presentation/AppModelTests.swift && git commit -m "feat: AppModel aggregates service state for the UI"`

---

### Task 12: 通知（`UserNotifier` の実装）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/NoticeContent.swift`, `Sources/AutoNoteCore/Presentation/NoticeRelay.swift`
- Create: `Sources/AutoNoteApp/SystemUserNotifier.swift`
- Modify: `Resources/Info.plist`（`NSUserNotificationAlertStyle` = `alert` を足す）
- Test: `Tests/AutoNoteCoreTests/Presentation/NoticeContentTests.swift`

**Interfaces:**
- Consumes: `UserNotifier`, `UserNotice`, `UserNoticeAction`（計画 03 の宣言。下の表の case が揃っていること）、`RecordingEvent`（計画 02）、`MeetingRow`（Task 5）、`QueueSnapshot`（計画 05）
- Produces:
  - `public struct NoticeButton: Equatable, Sendable { public var id: String; public var title: String }`
  - `public struct NoticeContent: Equatable, Sendable { public var id: String; public var category: String; public var title: String /* 常に "AutoNote" */; public var body: String; public var buttons: [NoticeButton]; public var userInfo: [String: String]; public static func make(_ n: UserNotice) -> NoticeContent; public static func action(category: String, buttonID: String?, userInfo: [String: String]) -> UserNoticeAction? }`（`buttonID` nil は通知そのものを押した場合）
  - `public enum NoticeRelay { public static func notices(for e: RecordingEvent) -> [UserNotice]; public static func notices(previous: QueueSnapshot, current: QueueSnapshot, rows: [MeetingRow]) -> [UserNotice] }`
  - `public enum PrivacyPane { public static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!; public static let systemAudio = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")! }`
  - App: `@MainActor final class SystemUserNotifier: NSObject, UserNotifier, UNUserNotificationCenterDelegate { init(onAction: @escaping @MainActor (UserNoticeAction) -> Void); func requestAuthorization() async }`

通知の中身（○○ は機材名。文言が要件書にあるものは一字一句そのまま。［私の判断］の行だけ本計画で決めた）:

| `UserNotice` | category / id | 本文 | ボタン → `UserNoticeAction` |
|---|---|---|---|
| `.countdown(device:seconds:)` | `countdown` / `countdown` | ○○が接続されました。N 秒後に録音を始めます（§4.1・11.4） | 取り消す → `.cancelCountdown` |
| `.newDevice(device:uid:)` | `new_device` / `new-device-<uid>` | ○○が接続されました。この機材で自動録音しますか？（§11.3） | はい → `.registerDevice(uid)`、いいえ → `.declineDevice(uid)`、今後聞かない → `.ignoreDevice(uid)` |
| `.connectedAtLaunch(device:uid:)` | `connected_at_launch` / `connected-<uid>` | ○○が接続されています。録音を始めますか？（§11.1。押すまで残す） | 開始 → `.startRecording(uid)` |
| `.micSilent` | `mic_silent` / `mic-silent` | マイクが無音です。機材と許可を確認してください（§5.7） | システム設定を開く［私の判断］ → `.openPrivacy(.mic)` |
| `.systemAudioSilent` | `system_audio_silent` / `system-audio-silent` | システム音声が届いていません。システム音声の録音許可と、会議アプリの音が出ているかを確認してください（§5.7） | システム設定を開く → `.openPrivacy(.system)` |
| `.diskLow` | `disk` / `disk` | ディスクの空きが 1GB を切りました［私の判断］ | なし |
| `.diskCritical` | `disk` / `disk` | ディスクの空きが 500MB を切ったため録音を停止しました［私の判断］ | なし |
| `.minutesReady(meetingID:title:)` | `minutes_ready` / `minutes-<id>` | 議事録ができました: <title>［私の判断］ | 開く → `.openMeeting(id)` |
| `.minutesNotGenerated(meetingID:reason:)` | `minutes_missing` / `minutes-<id>` | 議事録 未生成: <reason>（「議事録 未生成」は §8.4） | 再実行 → `.regenerate(id)` |
| `.automationFailed(name:meetingID:)` | `automation_failed` / `automation-<id>-<name>` | Automation 失敗: <name>（§14.5） | 再実行 → `.rerunAutomation(name:meetingID:)` |

ボタンなしで通知を押したら、`meeting_id` があれば `.openMeeting(id)`、無ければ `.openWindow`。

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func countdownContent()   // .countdown(device: "OpenRun Pro 2 by Shokz", seconds: 5) → body "OpenRun Pro 2 by Shokzが接続されました。5 秒後に録音を始めます"、buttons ["取り消す"]、id "countdown"
@Test func everyNoticeHasTableText()       // 表の 10 行それぞれ body と buttons の title を照合
@Test func buttonsMapBackToActions()       // make で作った content の各ボタンを action(category:buttonID:userInfo:) に通すと表の UserNoticeAction
@Test func tapWithoutButton()              // minutes_ready を buttonID nil → .openMeeting(id)、disk → .openWindow
@Test func relayRecordingEvents() {
    #expect(NoticeRelay.notices(for: .silence(.mic)) == [.micSilent])
    #expect(NoticeRelay.notices(for: .silence(.system)) == [.systemAudioSilent])
    #expect(NoticeRelay.notices(for: .bookmarked(b)).isEmpty)
}
@Test func relayFinishedJobs()             // previous に running の id、current に無い／done、rows の state minutes_generated → [.minutesReady(id, title)]。transcript_only → [.minutesNotGenerated(id, reason: "Claude Code で議事録を作れませんでした。文字起こしだけを書き出しました")]
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter NoticeContentTests` → Expected: `cannot find 'NoticeContent' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
Core の 2 ファイルを書く。`SystemUserNotifier` は init で表の category を `UNNotificationCategory` として登録し、`post` は `NoticeContent.make` から `UNMutableNotificationContent` を作って `add`（同じ id は置き換わる）、`withdraw` は配信済みと待機中の両方から消す。`willPresent` は `[.banner, .list, .sound]` を返す（前面でも出す）。`didReceive` は `NoticeContent.action` に通して `onAction` を呼び、`.openPrivacy` は App 側で `NSWorkspace.shared.open(PrivacyPane.…)`。`Info.plist` に `NSUserNotificationAlertStyle`（文字列 `alert`）を足す。
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter NoticeContentTests && swift build --product AutoNoteApp` → Expected: PASS、ビルド成功
- [ ] **Step 5: コミット** — `git add Sources/AutoNoteCore/Presentation Sources/AutoNoteApp/SystemUserNotifier.swift Resources/Info.plist Tests/AutoNoteCoreTests/Presentation/NoticeContentTests.swift && git commit -m "feat: user notifications with action buttons"`

---

### Task 13: アプリの骨組み（組み立て、メニューバー、終了確認、起動時の確認、ログイン時起動、ショートカット）

計画 00 の骨組み（`MenuBarExtra` と「マイク許可を確認」）を本番の形に置き換える。

**Files:**
- Modify: `Sources/AutoNoteApp/AutoNoteApp.swift`（スパイクの本体を消して書き直す）
- Create: `Sources/AutoNoteApp/AppEnvironment.swift`, `AppDelegate.swift`, `MenuBarContent.swift`, `HotKeyCenter.swift`, `LoginItem.swift`, `LaunchPrompts.swift`, `WorkspaceOpener.swift`

**Interfaces:**
- Consumes: 計画 01〜05 の各サービスの init（それぞれの計画の Interfaces どおり）、Task 1〜12 のすべて
- Produces:
  - `@MainActor final class AppEnvironment { static func make(environment: [String: String]) async throws -> AppEnvironment; let paths: AppPaths; let model: AppModel; let ports: AppPorts; let server: SocketServer; let notifier: SystemUserNotifier; let settings: SettingsStore; let portable: PortableConfigStore; let automationsFile: AutomationsFile; let devices: DeviceRegistry; let engines: EngineCatalog; let models: ModelManager }`
  - `final class AppDelegate: NSObject, NSApplicationDelegate`（`applicationDidFinishLaunching`、`applicationShouldTerminate`、`applicationWillTerminate`）
  - `@MainActor final class HotKeyCenter { init(onPress: @escaping @MainActor (ShortcutAction) -> Void); func apply(_ b: ShortcutBindings) -> [ShortcutAction: OSStatus] /* noErr 以外は登録失敗 */ }`
  - `enum LoginItem { static func set(_ on: Bool) throws; static var status: SMAppService.Status { get }; static func openSettings() }`
  - `struct WorkspaceOpener: FileOpener`（Obsidian が入っていれば `ObsidianLink.url(for:)`、無ければ既定のアプリ）

- [ ] **Step 1: 組み立てと起動の順番を書く**
`AppEnvironment.make`: `AppIdentity.paths(environment:)` → 計画 01〜05 のサービスを作る → `PostProcessingQueue` の段階の**最後**に `AutomationsStage` を入れる → アダプタで `AppPorts` → `AppModel` → `SocketServer(socketURL: paths.socketFile, handler: CommandRouter(ports:))`。

`applicationDidFinishLaunching` の順番:
1. `AppEnvironment.make`。`server.start()` が `.alreadyRunning` なら（別のインスタンスが動いている）ログに書いて `NSApp.terminate(nil)`
2. 通知の許可を求め、`AppModel.run()` と `RecordingAutomationTrigger.consume`、`NoticeRelay` を流す購読（`RecordingEvent` と `QueueSnapshot` → `notifier.post`）を起こす
3. 計画 01〜05 が「アプリ起動時に呼ぶ」とした開始処理（`_autonote/` の写しの更新、デバイス監視、待ち行列の再開、保持期限の定期処理）を呼ぶ
4. クラッシュ復旧: `meetings.interrupted()` の各件に `NSAlert`（`NSApp.activate()` してから）。本文「前回の録音が途中で終わっています。文字起こしと議事録を作りますか？」、ボタン「はい」→ `.recoverInterrupted(id)`、「破棄」→ `.discardInterrupted(id)`（§5.8）
5. 初回注意書き: `Settings.consentNoticeShown == false` なら小さなウィンドウ（`Window` scene、id `consent`）で「録音は相手の同意を得て行ってください」と「OK」。OK で `consentNoticeShown = true` を保存（§11.6）
6. ログイン時起動の突き合わせ: `Settings.launchAtLogin` と `LoginItem.status` が食い違えば設定に合わせて `register`/`unregister`
7. `HotKeyCenter.apply(settings.shortcuts)`。押されたら `.bookmark` → `perform(.bookmark(nil))`、`.toggleRecording`、`.togglePause`

`applicationShouldTerminate`: `QuitPolicy.decide(model.recorder.state, reason:)`。`confirm` は `NSAlert`（本文 `QuitPolicy.confirmMessage`、ボタン「停止して終了」「キャンセル」）。停止を選んだら `.terminateLater` を返し、`perform(.stop)` の完了（最大 10 秒）を待って `NSApp.reply(toApplicationShouldTerminate: true)`。`NSWorkspace.willPowerOffNotification` を受けたら `reason = .powerOff`（確認なしで停止して終了。間に合わなければ §5.8 に任せる）。`cancelCountdownThenTerminate` はカウントダウンを取り消してから終了。SIGTERM は `DispatchSource.makeSignalSource(signal: SIGTERM)`（`signal(SIGTERM, SIG_IGN)` の後）で受けて `reason = .powerOff` で `NSApp.terminate(nil)`。`applicationWillTerminate` で `server.stop()`（ソケットのファイルを消す。E2E 7f が見る）。
- [ ] **Step 2: 画面とホットキーを書く**

- `AutoNoteApp`: `@NSApplicationDelegateAdaptor(AppDelegate.self)`。`MenuBarExtra { MenuBarContent } label: { … }`。label はアイドル時 `Image(systemName: "waveform")` だけにする（E2E 7b の項目名 `waveform` を保つ）。録音中・一時停止中・猶予中は `TimelineView(.periodic(from: .now, by: 1))` で `Image(systemName: p.symbol)` と `Text(p.title)`
- `MenuBarContent`: `model.menuBar(now:)` の `items` を順に描く。文言: 録音開始 / 停止 / 一時停止 / 再開 / ブックマーク / 取り消す / 言語（自動・日本語・英語の 3 択。§6.4）/ ウィンドウを開く / 最新の議事録を開く / 設定…（`SettingsLink`）/ 終了（⌘Q）。`.status` は押せない行。`.minutesMissing` を押すと `.regenerate`、`.automationFailed` を押すと `.rerunAutomation`。ウィンドウを開くは `openWindow(id: "main")` と `NSApp.activate()`
- `HotKeyCenter`: Carbon の `RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x414E4F54 /* 'ANOT' */, id: 番号), GetEventDispatcherTarget(), 0, &ref)` と `InstallEventHandler`（`kEventClassKeyboard` / `kEventHotKeyPressed`）。`apply` は前の登録を全部外してから登録し直す。アクセシビリティ許可は不要
- `LoginItem`: `SMAppService.mainApp.register()` / `unregister()`。`.requiresApproval` なら `SMAppService.openSystemSettingsLoginItems()`
- [ ] **Step 3: ビルドが通ることを確かめる** — Run: `swift build && scripts/build-app.sh` → Expected: 成功。`codesign --verify` まで通る
- [ ] **Step 4: 起動して確かめる**
Run: `open build/AutoNote.app`
確認する（実装者）: メニューバーに waveform のアイコンがあり、メニューに「録音開始」「ウィンドウを開く」「最新の議事録を開く」「設定…」「終了」がある。初回は注意書きのウィンドウが出て、OK 後に再起動すると出ない。`build/AutoNote.app/Contents/MacOS/autonote status` が「録音器: 待機」を返す（ソケット経由）。⌃⌥B を押しても（録音していないので）何も起きず落ちない。

👤 利用者（マイクとシステム音声の許可、通知の許可が要る）:
- 「録音開始」→ アイコンが録音中になり経過時間が進む。⌃⌥B でブックマーク、⌃⌥P で一時停止と再開
- 録音中に「終了」→「録音中です。停止して終了しますか？」が出る。キャンセルで続き、停止して終了で止まって終わる
- 設定（Task 15 の前なら `settings.json` を手で）でログイン時起動をオンにし、ログアウト・ログインで常駐する
- 通知の許可ダイアログが出て、許可後のスタイルが「通知パネル」になっている（システム設定 › 通知 › AutoNote）
- [ ] **Step 5: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed（7・7b は waveform のまま PASS）。続けて `git add Sources/AutoNoteApp && git commit -m "feat: app shell with menu bar, quit confirmation, launch prompts, login item and hotkeys"`

---

### Task 14: メインウィンドウ

**Files:**
- Create: `Sources/AutoNoteApp/MainWindow/MainWindow.swift`, `MeetingListView.swift`, `StatusHeader.swift`, `LiveTranscriptView.swift`, `RecordingDetailView.swift`, `ProcessingDetailView.swift`, `CompletedDetailView.swift`, `MinutesEditor.swift`, `TooShortView.swift`, `ImportSheet.swift`
- Modify: `Sources/AutoNoteApp/AutoNoteApp.swift`（`Window("AutoNote", id: "main")` を足す）

**Interfaces:**
- Consumes: `AppModel`, `UserAction`（Task 11）、`MeetingsPort`（`minutes`・`transcript`・`saveMinutes`・`hasExternalChanges`・`manifest`。Task 7）、`LiveLine`, `LiveTranscriptBuffer`, `ObsidianLink`（Task 10）、`WorkspaceOpener`（Task 13）
- Produces: `struct MainWindow: View`（`NavigationSplitView`。左 `MeetingListView`、右は選んだ会議の `MeetingRow.state` で切り替える）

- [ ] **Step 1: 画面を書く**
固定の文言（要件書どおり）と振る舞い:
- 上部の `StatusHeader`: 録音中・一時停止中・猶予中は会議の選択に関係なく常に「録音中」または「一時停止中」と経過時間（§5.3）。猶予中は「機材が外れました。N 秒後に停止」。`diskWarning`、「出力フォルダが見つかりません」（§9.5）、`lastError` も帯で出す
- 左の一覧: `model.meetings`。日付・時刻・タイトル・長さ・状態（Task 9 と同じ表示語）、`progressLabel`、無音警告の印（`exclamationmark.triangle`）、「Automation 失敗: ○○」の印
- 録音中: 停止・一時停止（再開）・ブックマークのボタン、言語の切替。`LiveTranscriptView` は時刻（`TimelineTime.hhmmss`）・話者（自分 / 相手 / 不明）・本文。`isFinal == false` は `.foregroundStyle(.secondary)`（§6.3 薄い色）。ブックマークは `bookmark.fill` の印と時刻、一時停止は「── 一時停止 ──」の区切り。`ScrollView` は `.defaultScrollAnchor(.bottom)` で追従し、`onScrollGeometryChange` で最下部から離れたら追従をやめて「最新へ」ボタンを出す。押すと最後の行へ戻り追従を再開
- 処理中: `StageLabel` の進捗（`ProgressView(value:)`）と、`transcript(id, kind: .live)` のリアルタイム版を同じ `LiveTranscriptView` で（読み取り専用、追従なし）
- 短すぎる録音: 「1 分未満の短すぎる録音です」と「文字起こしする」→ `.transcribeTooShort(id)`、「破棄」→ `.discardTooShort(id)`（§5.9）
- 議事録 未生成（`transcript_only` と `failed`）: 「議事録 未生成」と「再実行」→ `.regenerate(id)`（§8.4）。確定版の文字起こしを下に出す
- 完了: `MinutesEditor` でタイトルと各節（3行要約、決定事項、議題、Next Action の内容・担当・期限）を編集できる。ブックマーク一覧、確定版文字起こし（読み取り専用、§9.4）。「保存」: タイトルが変わっていれば改名シートに「ファイル名も変更する」のチェック（既定オフ。§9.1）。`hasExternalChanges` が true なら「Vault の会議ファイルがアプリの外で編集されています。上書きしますか？」で確かめてから `saveMinutes`。「再生成」も同じ確認の後 `.regenerate(id)`（§8.4）。「Obsidian で開く」→ `WorkspaceOpener`。「この会議を削除」→ 確認「この会議を削除しますか？音声、アプリ内のデータ、Vault の会議ファイル、_index.md の行をまとめて削除します。元に戻せません。」の後 `.delete(id)`（§12）
- 取り込み: ウィンドウ全体の `.dropDestination(for: URL.self)`（拡張子 wav / m4a / mp3 / mp4）とツールバーの「音声ファイルを取り込む…」（`NSOpenPanel`）。`ImportSheet` で日時を選ばせる（既定はファイルの作成日時 `URLResourceValues.creationDate`。§10）→ `.importAudio(url, startedAt:)`
- 通知の `.openMeeting(id)` で `selectedMeetingID` が変わったらウィンドウを開いてその会議を選ぶ
- [ ] **Step 2: ビルドが通ることを確かめる** — Run: `swift build && scripts/build-app.sh` → Expected: 成功
- [ ] **Step 3: 起動して確かめる**
Run: `autonote dev render-fixture --out /tmp/an-vault`（計画 01）で架空の会議を書き、`settings.json` の出力フォルダを `/tmp/an-vault` にして `open build/AutoNote.app`
確認する（実装者）: 一覧にフィクスチャの会議が出て、選ぶと議事録・ブックマーク・文字起こしが出る。「Obsidian で開く」で Obsidian（無ければ既定のエディタ）が開く。タイトルを変えて保存すると改名シートが出て、チェックなしでは Vault のファイル名が変わらず frontmatter の title と `_index.md` が変わる。`/tmp/an-vault` を別名に移すと 30 秒以内に「出力フォルダが見つかりません」が出て、戻すと消える。音声ファイルをドラッグすると日時のシートが出て、取り込むと一覧に処理中で現れる。

👤 利用者: 録音を 2 分ほどして、リアルタイム文字起こしが流れ、部分結果が薄い色で出ること、上へスクロールすると追従が止まり「最新へ」で戻れること、ブックマークの印が出ることを見る。30 秒で止めた録音が「短すぎる録音」になり「文字起こしする」「破棄」が効くこと
- [ ] **Step 4: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed。続けて `git add Sources/AutoNoteApp && git commit -m "feat: main window with meeting list, live transcript and minutes editor"`

---

### Task 15: 設定画面（8 タブ）

**Files:**
- Create: `Sources/AutoNoteCore/Presentation/SettingsDrafts.swift`
- Create: `Sources/AutoNoteApp/Settings/SettingsView.swift`, `GeneralTab.swift`, `DevicesTab.swift`, `TranscriptionTab.swift`, `DictionaryTab.swift`, `MinutesTab.swift`, `AutomationsTab.swift`, `RetentionTab.swift`, `ShortcutsTab.swift`, `ShortcutRecorderField.swift`
- Modify: `Sources/AutoNoteApp/AutoNoteApp.swift`（`Settings { SettingsView() }` scene）
- Test: `Tests/AutoNoteCoreTests/Presentation/SettingsDraftsTests.swift`

**Interfaces:**
- Consumes: 下の表の各項目、`AutomationsFile`（Task 2）、`AutomationsPort`（Task 7）、`KeyCombo`, `ShortcutBindings`（Task 10）、`HotKeyCenter`, `LoginItem`（Task 13）
- Produces:
  - `public struct DictionaryDraft: Equatable, Sendable { public var terms: [String]; public var replacements: [Replacement]; public var fillers: [String]; public init(_ f: DictionaryFile); public func toFile() throws(AppCommandError) -> DictionaryFile }`
  - `public struct AutomationDraft: Equatable, Sendable { public var definition: AutomationDefinition; public static func validate(_ d: AutomationDefinition, existing: [AutomationDefinition]) -> [String] }`
  - `public enum SettingsLimits { public static let countdownSeconds: ClosedRange<Int> = 0...30; public static let graceSeconds: ClosedRange<Int> = 1...600; public static func clamp(_ s: Settings) -> Settings }`

| タブ | 項目 | 読み書き先 | 備考 |
|---|---|---|---|
| 一般 | 出力フォルダ | `Settings.outputFolder: URL?` | `NSOpenPanel`（フォルダ） |
| 一般 | ログイン時起動 | `Settings.launchAtLogin: Bool` ＋ `LoginItem.set` | `.requiresApproval` なら「システム設定で許可してください」とボタン |
| 一般 | `claude` のパス | `Settings.claudePath: String?` | 「探す」で `/bin/zsh -lc 'command -v claude'` |
| 一般 | モデル | `Settings.claudeModel: String?` | 空なら Claude Code の既定（§8.1） |
| 一般 | 要約器の種別 | `Settings.summarizerKind: String` | 選択肢は `claude_code` だけ（§8.5） |
| 一般 | CLI | なし | `sudo mkdir -p /usr/local/bin && sudo ln -sf "<Bundle>/Contents/MacOS/autonote" /usr/local/bin/autonote` を表示してコピーボタン（§16） |
| 一般 | 外部送信 | なし | 固定文「音声・文字起こし・議事録はこの Mac に保存します。外部へ送るのは、議事録を作るときに Claude Code へ渡す文字起こしテキスト（全文、辞書の用語、ブックマーク）だけで、音声は送りません。」（§17） |
| 機材 | 接続中・登録済み・無視 | `DeviceRegistry`（`_autonote/devices.json`） | 登録・無視・削除。別の Mac で登録した機材には「この Mac で再登録」（§9.5・11.3） |
| 機材 | カウントダウン秒数 | `Settings.countdownSeconds: Int`（既定 5） | `SettingsLimits.countdownSeconds` |
| 機材 | 切断猶予秒数 | `Settings.graceSeconds: Int`（既定 30） | `SettingsLimits.graceSeconds`［私の判断］ |
| 機材 | 型番一致で開始 | `DeviceRegistry.setMatchByModel(uid:_:)` | 機材ごと（§11.2） |
| 文字起こし | リアルタイム／確定版のエンジンとモデル | `Settings.liveEngine: String`, `liveModel: String?`, `batchEngine: String`, `batchModel: String?` | `EngineCatalog.engines()` の `isAvailable == false` は選べない（§6.2） |
| 文字起こし | モデルのダウンロード | `ModelManager.models/download/delete` | 大きさと進捗。未取得のモデルを選んだら注意 |
| 文字起こし | 既定の言語 | `Settings.defaultLanguage: Language`（既定 `.ja`） | §6.4 |
| 文字起こし | エコー除去 | `Settings.voiceProcessing: Bool`（既定 false） | 「他のアプリの音が小さくなることがあります」と注記（§5.6） |
| 文字起こし | フィラー除去 | `Settings.fillerRemoval: Bool`（既定 true） | §6.5 |
| 辞書 | 用語・置換・フィラー | `PortableConfigStore.loadDictionary/saveDictionary` | タブを開くときとウィンドウが前面に来たときに読み直す（§7.2）。未保存の編集があるときは上書きしない |
| 議事録 | プロンプト | `PortableConfigStore.loadPrompt/savePrompt`（`_autonote/prompt.md`） | `TextEditor`（§8.3） |
| 議事録 | frontmatter テンプレート | `PortableConfigStore.loadFrontmatterTemplate/saveFrontmatterTemplate` | 「title・date・status・autonote_id はテンプレートから消しても必ず付きます」と注記（§9.2） |
| Automations | 定義 | `AutomationsFile.load/save` | 追加・編集・削除。権限の警告は上に帯で（§14.2） |
| Automations | 手動実行 | `AutomationsPort.run(name:meetingID:)` | 会議を選ぶ |
| Automations | 実行ログ | `AutomationsPort.recentRuns(limit: 50)` | 時刻・名前・会議・終了コード／タイムアウト・所要時間。stdout/stderr の末尾とフォルダを開く |
| Automations | 書き出し / 読み込み | `AutomationsFile.export/importReplacing` | `NSSavePanel` / `NSOpenPanel`（§14.2） |
| 保持 | 音声の保持日数 | `Settings.audioRetentionDays: Int?`（既定 30、nil は削除しない） | §12 |
| ショートカット | ブックマーク、録音開始・停止、一時停止 | `Settings.shortcuts: ShortcutBindings` | `ShortcutRecorderField`。保存後 `HotKeyCenter.apply`。失敗は「このショートカットは他のアプリが使っています」 |

- [ ] **Step 1: 失敗するテストを書く**
```swift
@Test func dictionaryDraftTrimsAndDropsEmpty() throws          // terms ["AutoNote", "  所沢 ", ""] → toFile().terms == ["AutoNote", "所沢"]
@Test func dictionaryDraftRejectsHalfEmptyReplacement()        // [オートノート => AutoNote, クーバ => " "] → throws .invalid("置換の左右どちらかが空です（2 行目）")
@Test func automationDraftValidation()   // 名前 "" → ["名前を入れてください"]、command " " → ["コマンドを入れてください"]、timeout 0 → ["タイムアウトは 1〜86400 秒にしてください"]、既存と同名 → ["同じ名前の Automation があります"]
@Test func settingsClamp()   // countdownSeconds 45 → 30、-1 → 0、graceSeconds 0 → 1
```
- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter SettingsDraftsTests` → Expected: `cannot find 'DictionaryDraft' in scope` でビルド失敗
- [ ] **Step 3: 実装する**
`SettingsDrafts.swift` を書いて通す。続けて各タブを表どおりに書く。保存は各タブの「保存」ボタンで `SettingsLimits.clamp` を通してから `SettingsStore.save`。`ShortcutRecorderField` は入力欄にフォーカスがある間だけ `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` でキーを拾い（アプリ内なので許可不要）、`KeyCombo.validate` と `ShortcutBindings.duplicates` に引っかかれば保存させない。Automations の編集シートは名前・きっかけ（4 択）・コマンド（`TextEditor`）・タイムアウト秒で、`AutomationDraft.validate` の結果を下に出す。
- [ ] **Step 4: 通過とビルドを確かめる** — Run: `swift test --filter SettingsDraftsTests && scripts/build-app.sh` → Expected: PASS、ビルド成功
- [ ] **Step 5: 起動して確かめる**
Run: `open build/AutoNote.app` → メニュー「設定…」
確認する（実装者）: 8 タブが並ぶ。辞書を編集・保存すると `<出力フォルダ>/_autonote/dictionary.md` が変わり、ファイルを外で書き換えてタブを開き直すと反映される。プロンプトと frontmatter も同様。Automations に `echo "$AUTONOTE_EVENT" >> /tmp/an-auto.txt` を足し、手動実行でログ一覧に 1 行増え、`/tmp/an-auto.txt` に `minutes_generated` が書かれる。`chmod 664 ~/Library/Application\ Support/AutoNote/automations.json` で警告の帯が出る。ショートカットを ⌃⌥K に変えると ⌃⌥B が効かなくなり ⌃⌥K でブックマークになる（録音中に確認するのは 👤 利用者）。
👤 利用者: モデルのダウンロード（ネットワークと数百 MB の空き）、ログイン時起動のオン・オフ
- [ ] **Step 6: E2E を回してコミット** — Run: `scripts/e2e-check.sh` → Expected: 0 failed。続けて `git add Sources/AutoNoteCore/Presentation/SettingsDrafts.swift Sources/AutoNoteApp Tests/AutoNoteCoreTests/Presentation/SettingsDraftsTests.swift && git commit -m "feat: settings window with eight tabs"`

---

### Task 16: E2E 更新（7/7b の拡張と Automations）、全 PASS、README 更新、コミット

**Files:**
- Modify: `scripts/e2e-check.sh`（`check_app_launch` と新しい項目、CHECKS 配列、先頭の説明）
- Modify: `README.md`

**Interfaces:**
- Consumes: `AUTONOTE_DATA_DIR`（Task 1）、`autonote status --json` / `bookmark` / `automations run`（Task 9）、`Tests/Fixtures/manifest.json`（計画 01 のフィクスチャ）
- Produces: E2E 項目 6b・7〜7f

- [ ] **Step 1: E2E の項目を書く**

- 先頭で `DATA="$(mktemp -d /tmp/an-e2e.XXXXXX)"` を作り（ソケットのパスを短く保つ。Review Focus 1）、`cleanup` で消す
- 7「AutoNoteApp を起動」: 起動前に `${DATA}/automations.json` を 0600 で書く（下の定義）、`${DATA}/recordings/<id>/manifest.json` に `Tests/Fixtures/manifest.json` を写す（`<id>` は `plutil -extract id raw -o - Tests/Fixtures/manifest.json`）。`AUTONOTE_DATA_DIR="${DATA}" AUTONOTE_E2E_OUT="${DATA}/auto-out.txt" "${bin}" &` で起動する。プロセスは 7f まで生かす（今の「7b の後に kill」を 7f へ移す）
- 7b: 今のまま（アイドル時の項目名 `waveform`）
- 7c「`autonote status` がソケット経由で idle」: 最大 10 秒 `[[ -S "${DATA}/autonote.sock" ]]` を待ち、`AUTONOTE_DATA_DIR="${DATA}" "${cli}" status --json` の出力を `plutil -extract recorder.state raw -o - -` に通して `idle`、終了コード 0 なら PASS。人向けの `status` が「録音器: 待機」を含むことも見る
- 7d「録音していないときの `autonote bookmark` は失敗」: 終了コード 1、stderr に「録音中ではありません」
- 7e「Automation の手動実行」: `"${cli}" automations run e2e-echo <id>` が終了コード 0。`${DATA}/auto-out.txt` が `minutes_generated <id>` の 1 行
- 7f「Automation のログ」: `${DATA}/logs/automations/*/result.json` が 1 つあり `plutil -extract exit_code raw` が 0、`stdout.txt` がある。ここでアプリを kill し、`${DATA}/autonote.sock` が消えていることも見る（SIGTERM で `server.stop()` を呼ぶ）
- 7 が SKIP（GUI なし）なら 7b〜7f も「アプリが起動していない」で SKIP
- 6b「アプリ未起動の CLI」（CHECKS で `check_cli` の直後、7 の前）: データ領域を差し替えた CLI は自動起動しないので、`AUTONOTE_DATA_DIR="${DATA}" "${cli}" status` が 3 秒以内に終了コード 1・stderr「AutoNote が起動していません」なら PASS

Automations の定義（E2E 用の偽コマンド）:
```json
[{"name": "e2e-echo", "enabled": true, "on": "minutes_generated", "command": "echo \"$AUTONOTE_EVENT $AUTONOTE_MEETING_ID\" > \"$AUTONOTE_E2E_OUT\"", "timeout_sec": 30}]
```
- [ ] **Step 2: 失敗を検出できることを確かめる** — 既存の `E2E_EXPECT_VERSION` と同じく、期待値だけを変える環境変数 `E2E_EXPECT_RECORDER_STATE`（既定 `idle`）と `E2E_EXPECT_AUTOMATION_OUT`（既定 `minutes_generated <id>`）を足し、先頭の説明に書く。Run: `E2E_EXPECT_RECORDER_STATE=recording scripts/e2e-check.sh --quick; E2E_EXPECT_AUTOMATION_OUT=x scripts/e2e-check.sh --quick` → Expected: 1 回目は 7c が FAIL、2 回目は 7e が FAIL（どちらも終了コード 1）
- [ ] **Step 3: README を更新する**
足す節: 「使い方（CLI）」（§16 の表を短く。`/usr/local/bin` へのリンクは設定 › 一般に案内がある）、「Automations」（`~/Library/Application Support/AutoNote/automations.json`、§14.6 の例、権限 600、`/bin/zsh -lc`、環境変数の一覧、ログの場所）、「ショートカット」（既定 ⌃⌥B / ⌃⌥R / ⌃⌥P、アクセシビリティ許可は不要）、「ログイン時起動」（`build/AutoNote.app` を動かすと登録先が変わるので、使う場所に置いてからオンにする）、「開発用: `AUTONOTE_DATA_DIR`」（E2E が使う。設定すると CLI はアプリを自動起動しない）、`scripts/config.sh`（Bundle ID と証明書名はここだけで変える）
- [ ] **Step 4: 全 PASS を確かめる** — Run: `scripts/e2e-check.sh` → Expected: `N passed, 0 failed, M skipped`。6b・7・7c〜7f が PASS（GUI がある機械で。7b はアクセシビリティ権限が無ければ SKIP でよい）。`swift test` も全 PASS
- [ ] **Step 5: コミット** — `git add scripts/e2e-check.sh README.md && git commit -m "test: e2e covers socket status, bookmark error and automation run; docs for CLI and automations"`

---

## Self-Review（保存前に実施した結果）

1. 要件書の対応: §3.2（`SMAppService.mainApp` Task 13、`UNUserNotificationCenter` Task 12、UNIX ソケット Task 5・6）、§4.1 の 1〜8（常駐 13、通知と取り消し 12・13、表示 14、ブックマーク 10・13、猶予表示 10・14、進捗 10・14、完了通知と Automations 4・12、編集 14）、§5.3〜5.5・5.8・5.9 補足（10・13・14）、§6.3（10・14）、§7.2（15）、§8.3・8.4（14・15）、§9.1・9.5（14・15）、§11.3・11.4・11.6（12・13・15）、§14 全部（2〜4・15）、§15 全部（13〜15）、§16 全部（5・8・9）、§17（15 の明記、ログに本文を書かない＝Automations の stdin にも本文を入れない）、M4（1）。欠けは無し
2. ステップ: 「適切に」「など」で終わる手順を消し、各実装ステップに名前・ファイル・決めた値（秒数、文言、パス、記号名）を入れた。関数本体は書いていない（`config.sh` は設定値そのものなので全文）
3. 型の一致: `RecorderSnapshot`・`UserNoticeAction`・`AutomationRunRecord`・`MeetingRow`・`StageLabel.text(stage:progress:)`・`AppCommandError`・`ShortcutBindings`・`AutomationDispatcher.runOne` を各タスクの Interfaces で照合した。`runOne` は `AppCommandError`（Task 7）より前の Task 4 に置くと型が無いので、Task 7 で足すと明記した
4. Review Focus: 5 件とも担当タスクのテスト名を入れた（Task 3・6・10）。並列接続（Task 6 `concurrentClients`）、壊れた行（`badLineGetsBadRequest`）、壊れた automations.json（Task 2）もテストにある
5. 分量: 本計画は約 900 行で、要件書（約 810 行）と同程度。コードブロックはテストの名前と期待値が中心で、実装の本体は `scripts/config.sh` の 2 行だけ
