# AutoNote 計画 01〜06 の全体設計（共通契約）

- 作成日: 2026-10-25
- 役割: 計画 01〜06 が共有する前提をここに一度だけ書く。各計画はこの文書と要件書 `docs/superpowers/specs/2026-10-24-autonote-design.md` を参照し、ここで決めた名前・配置・境界を変えない。変える必要が出たら本書を先に直し、影響する計画を直す
- 根拠: 要件書（承認済み）、計画 00 の結果表 `docs/superpowers/research/2026-10-24-spike-results.md`、進捗ファイル `docs/superpowers/plans/2026-10-24-autonote-00-progress.md` の申し送り

## 1. 計画の並びと依存

| 計画 | ファイル | 作るもの | 前提にする計画 | ハードウェア |
|---|---|---|---|---|
| 01 | `2026-10-25-autonote-01-core-model-and-storage.md` | 会議モデル、会議タイムライン、manifest、設定、持ち運ぶ設定（`_autonote/`）、辞書、フィラー除去・置換、トラック結合と重複除去、Vault 書き出し（会議ファイル・`_index.md`）、フェイク群 | 00 | 不要 |
| 02 | `2026-10-25-autonote-02-audio-capture.md` | TCC まとめ確認、process tap、マイク、分割 WAV、無音検知、一時停止、ブックマーク、クラッシュ復旧、取り込み（音声ファイル → WAV） | 01 | Intel 機（👤 許可ダイアログ） |
| 03 | `2026-10-25-autonote-03-devices-and-auto-record.md` | デバイス監視・識別・登録、録音器の 5 状態、カウントダウン・猶予、起動時接続の扱い | 01, 02 | Shokz・3.5mm（👤） |
| 04 | `2026-10-25-autonote-04-transcription.md` | `LiveTranscriber` / `BatchTranscriber` の実装（DictationTranscriber、SpeechTranscriber、whisper.cpp）、モデル管理、リアルタイム供給、確定版の結合 | 01, 02 | Intel 機。Apple Silicon は 👤 で後から |
| 05 | `2026-10-25-autonote-05-minutes-and-queue.md` | `Summarizer`（Claude Code）、プロンプト、後処理の待ち行列（永続・段階再実行）、失敗時の `transcript_only`、再生成、保持と削除 | 01, 04 | 不要（`claude` は 👤 で 1 回確認） |
| 06 | `2026-10-25-autonote-06-ui-cli-automations.md` | メニューバー、メインウィンドウ、設定画面、UNIX ソケット、CLI、Automations、ログイン時起動、通知、ショートカット | 01〜05 | 不要 |

- 02 と 03 は 01 の後に並行して書けるが、実装は 02 → 03 の順。03 は 02 の `RecordingSession` を呼ぶ
- 04 は 02 と並行して実装できる（入力はファイルとフェイクの音声ストリーム）
- 05 は 04 の `BatchTranscriber` をフェイクで差し替えて先に実装できる
- 06 は最後。ただし各計画は自分の機能を `autonote` CLI の**開発用サブコマンド**（§7）で動かせるようにし、E2E から確認する

ブランチ: 計画ごとに `plan-NN` を切る。起点は直前の計画のブランチ（`plan-01` は `plan-00` から）。main への統合は利用者が決める。push はしない。

## 2. パッケージとモジュール配置

Swift パッケージは一つ。ライブラリ `AutoNoteCore` の中をフォルダで区切る（別ターゲットには分けない。分けると `@testable import` と Sendable 境界が増えるだけで利点がない）。

```
Sources/
  AutoNoteCore/
    Model/          計画 01: MeetingID, TimelineTime, Speaker, Language, Utterance, Transcript, Bookmark, Manifest, MeetingStatus, MinutesOutput
    Storage/        計画 01: AppPaths, SettingsStore, ManifestStore, PortableConfigStore（_autonote/ と写し）
    Dictionary/     計画 01: DictionaryFile, FillerRemover, Replacer, HintBudget
    Transcript/     計画 01: TranscriptMerger, EchoDeduplicator, TranscriptMarkdown
    Vault/          計画 01: MeetingFileName, FrontmatterTemplate, MeetingDocument, IndexFile, VaultWriter, VaultScanner
    Audio/          計画 02: AudioSource（protocol）, ProcessTapSource, MicrophoneSource, WAVSegmentWriter, SilenceMonitor, RecordingSession, CrashRecovery, AudioImporter
    Devices/        計画 03: DeviceMonitor, DeviceIdentity, DeviceRegistry, RecorderStateMachine, AutoRecordCoordinator
    Transcription/  計画 04: LiveTranscriber / BatchTranscriber（protocol）, DictationLiveTranscriber, SpeechLiveTranscriber, WhisperBatchTranscriber, WhisperLiveTranscriber, ModelManager, EngineCatalog, LiveFeed
    Minutes/        計画 05: Summarizer（protocol）, ClaudeCodeSummarizer, PromptBuilder, PostProcessingQueue, JobStore, Retention
    IPC/            計画 06: SocketServer, SocketClient, Protocol（JSON 行）
    Automations/    計画 06: AutomationsFile, AutomationRunner, AutomationsStage
    Presentation/   計画 06: AppModel と表示規則（SwiftUI の View は AutoNoteApp 側）
  AutoNoteTestSupport/   計画 01 が作るライブラリターゲット。フェイクとフィクスチャ。Tests と `autonote` の開発用サブコマンドだけが依存する
  AutoNoteApp/           計画 06（それまでは計画 00 の骨組みのまま。各計画は App を触らない）
  autonote/              CLI。計画 01 以降、`autonote dev …` の開発用サブコマンドを足していく。利用者向けコマンドは計画 06
Tests/
  AutoNoteCoreTests/     フォルダは Sources と同じ区切り
```

- `Package.swift` の変更は、計画 01（`AutoNoteTestSupport` 追加）と計画 04（whisper.cpp の `.binaryTarget`）だけ
- `Spikes/` は計画 04 の最後のタスクで削除する（AppleSpeechProbe は Apple Silicon 確認に使うため、それまで残す）。E2E の項目 8・14・15・15b は削除と同時に外す

## 3. 共有する型（計画 01 が定義し、以後の計画はこの名前と形を使う）

すべて `Sendable` な値型。`Codable` の JSON キーは snake_case（`JSONEncoder.keyEncodingStrategy = .convertToSnakeCase`）。日付は ISO 8601。

```swift
struct MeetingID: Hashable, Codable, Sendable { let rawValue: String }   // "20261024-1400-a1b2"。生成は MeetingID.make(start: Date) で末尾 4 桁は乱数 hex
struct TimelineTime: Codable, Comparable, Sendable { var seconds: Double } // 会議タイムライン（録音開始からの経過。一時停止中も進む）
//   .hhmmss  → "00:12:34"   .anchor → "t00-12-34"   .mmss → "12:34"（要件書 §9.2 のリンク表示）
enum Speaker: String, Codable, Sendable { case me, other, unknown }       // 表示名は 自分 / 相手 / 不明
enum Language: String, Codable, Sendable { case auto, ja, en }
enum Track: String, Codable, Sendable { case mic, system }
struct Utterance: Codable, Equatable, Sendable { var start: TimelineTime; var end: TimelineTime?; var speaker: Speaker; var text: String; var isFinal: Bool }
struct Transcript: Codable, Sendable { var utterances: [Utterance]; var engine: String; var language: Language }
struct Bookmark: Codable, Equatable, Sendable { var at: TimelineTime; var note: String? }
struct PauseInterval: Codable, Equatable, Sendable { var start: TimelineTime; var end: TimelineTime? }
struct TrackFile: Codable, Equatable, Sendable { var track: Track; var relativePath: String; var startOffset: TimelineTime; var durationSeconds: Double? }
enum MeetingStatus: String, Codable, Sendable { case recording, recorded, transcribing, transcribed, generating, minutesGenerated, transcriptOnly, failed, tooShort }
enum MeetingSource: String, Codable, Sendable { case live, imported }
struct DeviceRef: Codable, Equatable, Sendable { var name: String; var uid: String; var transport: String }   // manifest に残す起点機材。"import" は device 名 "import"
struct Manifest: Codable, Equatable, Sendable {
    var id: MeetingID; var title: String?; var startedAt: Date; var endedAt: Date?
    var source: MeetingSource; var device: DeviceRef?; var language: Language
    var tracks: [TrackFile]; var pauses: [PauseInterval]; var bookmarks: [Bookmark]
    var status: MeetingStatus; var silenceWarning: Bool; var autonoteVersion: String
}
struct MinutesOutput: Codable, Equatable, Sendable   // scripts/minutes-schema.json と同じ形（title, summary, decisions[{text,t}], agenda[{title,body,t}], next_actions[{text,owner?,due?,t}], suggested_terms）。t は "HH:MM:SS" の文字列のまま持ち、TimelineTime への変換は TimelineTime(hhmmss:) で行う
```

録音器の状態（要件書 §5.9）は計画 03 の `enum RecorderState { idle, countdown, recording, paused, grace }`。`MeetingStatus` とは別物。

計画 01 が決めた細部（2026-10-26 に各計画の草稿から取り込み）:
- JSON の形: `MeetingID` は文字列 1 つ、`TimelineTime` は数値（秒）1 つ、`MeetingStatus` の raw value は snake_case（`minutes_generated` など）
- 計画 01 が追加で定義する型: `AudioChunk(track:samples:start:hostTime:)`、`TrackTranscription`、`TranscriptFinalizer`（raw ＝ 結合と重複除去まで、final ＝ 置換とフィラー除去まで）、`SummaryInput`、`Job`、`StageContext`、`StageName`
- 取り込んだ音声（§10）は 1 トラックで `Track.mic`、話者は `source == .imported` を見て `unknown` にする（計画 02・04・05 はこれに合わせる）
- `Settings` の項目は計画 01 が**全計画分をまとめて**定義する。確定した一覧（型 / 既定）: `outputFolder: String?` / nil、`claudePath: String?` / nil、`claudeModel: String?` / nil、`summarizerKind: SummarizerKind` / `.claudeCode`、`launchAtLogin: Bool` / true、`defaultLanguage: Language` / `.ja`、`liveEngine` `liveModel` `finalEngine` `finalModel: String?` / nil（機種別の既定は計画 04 の `EngineCatalog`）、`voiceProcessing: Bool` / false、`fillerRemoval: Bool` / true、`countdownSeconds: Int` / 5（0〜30 に丸める）、`disconnectGraceSeconds: Int` / 30（5〜300 に丸める）、`startOnModelMatch: Bool` / false、`audioRetentionDays: Int` / 30（0 で削除しない）、`shortcuts: Shortcuts { bookmark, toggleRecording, togglePause: String }` / `"ctrl+option+b"` `"ctrl+option+r"` `"ctrl+option+p"`（文字列で保存。解釈は計画 06）、`consentNoticeShown: Bool` / false。各計画は自分の項目を Consumes に書き、この一覧と一致させる。後の計画が `Settings` を書き換えない
- 取り込んだ音声の manifest: `tracks: [TrackFile(track: .mic, relativePath: "tracks/import-000.wav", startOffset: 0, …)]`、`device: DeviceRef(name: "import", uid: "import", transport: "import")`
- `DeviceRef.transport` の値（小文字の文字列）: `builtin` `bluetooth` `usb` `aggregate` `virtual` `unknown` `import`。AutoNote が作る aggregate デバイスの UID は `com.yutaokoshi.autonote.tap.` で始める（計画 02。計画 03 はこの接頭辞のデバイスを機材として扱わない）
- 通知の種類 `UserNotice` / `UserNoticeAction` は計画 03 が `Devices/UserNotice.swift` に**全計画分の case をまとめて**宣言し、`FakeUserNotifier`（`posted: [UserNotice]`、`withdrawn: [String]`）を TestSupport に置く。計画 06 が `UNUserNotificationCenter` で実装する。通知に音は付けない（自アプリを tap から除外しても OS が鳴らす通知音は除外できないため。計画 02 の指摘）
  - `protocol UserNotifier: Sendable { func post(_ notice: UserNotice) async; func withdraw(id: String) async }`。`UserNotice` は `var id: String { get }`（同じ事象は同じ id で、取り下げに使う）
  - `UserNotice` の case: `deviceConnectedCountdown(DeviceRef, seconds: Int)`、`deviceSeenFirstTime(DeviceRef)`、`deviceAlreadyConnected(DeviceRef)`（起動時・復帰時）、`deviceGoneGrace(DeviceRef, seconds: Int)`、`silence(Track)`、`diskLow(availableBytes: Int64)`、`recordingTooShort(MeetingID)`、`interruptedRecordingFound(MeetingID)`、`minutesGenerated(MeetingID, title: String)`、`transcriptOnly(MeetingID)`、`claudeNotLoggedIn(MeetingID)`、`overwriteConfirmation(MeetingID)`、`outputFolderMissing`、`automationFailed(name: String, MeetingID)`
  - `UserNoticeAction` の case: `cancelCountdown`、`startNow(DeviceRef)`、`registerDevice(DeviceRef, answer: RegisterAnswer)`（`enum RegisterAnswer { yes, no, never }`）、`openMeeting(MeetingID)`、`retry(MeetingID)`、`resolveOverwrite(MeetingID, overwrite: Bool)`、`transcribeTooShort(MeetingID)`、`discardTooShort(MeetingID)`、`recoverInterrupted(MeetingID)`、`discardInterrupted(MeetingID)`、`openPrivacySettings`
- `Job`（計画 01 が定義、計画 05 の `JobStore` はこれを保存するだけ）: `id: String`、`meeting: MeetingID`、`generation: Int`（再生成のたびに +1。Automations の二重実行防止キーは `"\(meeting.rawValue):\(generation)"`）、`stages: [String]`、`completedStages: [String]`、`state: JobState`、`attempts: Int`、`lastError: String?`、`notBefore: Date?`、`createdAt: Date`、`transcriptEngine: String?`、`summaryFailure: String?`、`overwriteApproved: Bool`、`nextStage: String? { get }`
- `RecordingEvent`（計画 02 が定義。03・05・06 が購読する）: `started(MeetingID)`、`paused(TimelineTime)`、`resumed(TimelineTime)`、`bookmarked(Bookmark)`、`silenceWarning(SilenceWarning)`、`diskSpaceLow(availableBytes: Int64)`、`sourceFailed(Track, message: String)`、`microphoneDetached(TimelineTime)`、`microphoneAttached(TimelineTime, device: DeviceRef?)`、`stopped(Manifest, StopReason)`。`enum StopReason: String { manual, deviceGone, diskFull, appTerminating }`

## 4. 共有するプロトコル（定義する計画と、使う計画）

```swift
// 計画 02 が定義。実装: ProcessTapSource, MicrophoneSource。フェイク: FakeAudioSource（計画 01 の TestSupport に先に置き、02 で protocol に合わせる）
protocol AudioSource: Sendable {
    var track: Track { get }
    func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws   // AudioChunk: 16kHz/mono/Int16 の配列 + 会議タイムライン上の開始時刻 + ホスト時刻
    func stop() async
}

// 計画 04 が定義。計画 01 は TestSupport に FakeLiveTranscriber / FakeBatchTranscriber を置く（protocol は 01 で先に Transcription/Protocols.swift に書く。04 は実装だけ足す）
protocol LiveTranscriber: Sendable {
    func start(language: Language, hints: [String]) async throws -> AsyncStream<Utterance>   // isFinal=false の部分結果を同じ start で更新し、確定で isFinal=true
    func feed(_ chunk: AudioChunk) async
    func finish() async
}
protocol BatchTranscriber: Sendable {
    func transcribe(file: URL, language: Language, hints: [String], progress: @Sendable @escaping (Double) -> Void) async throws -> [Utterance]   // ファイル内相対時刻。呼び手が startOffset を足す
}

// 計画 05 が定義。計画 01 は TestSupport に FakeSummarizer を置く（protocol は 01 で Minutes/Protocols.swift に書く）
protocol Summarizer: Sendable {
    func summarize(_ input: SummaryInput) async throws -> MinutesOutput   // SummaryInput: 指示文、用語一覧、ブックマーク、Transcript、言語
}

// 計画 05 が定義する待ち行列の段階。計画 06 の Automations はこの protocol の実装として最後の段階に入る
protocol QueueStage: Sendable {
    var name: String { get }   // "transcribe" "summarize" "write_vault" "update_index" "automations"
    func run(_ job: inout Job, context: StageContext) async throws
}
```

## 5. 保存場所と設定

- アプリのデータ領域: `~/Library/Application Support/AutoNote/`。テストでは `AppPaths(root:)` で差し替え、開発・E2E では環境変数 `AUTONOTE_DATA_DIR` で差し替える（設定中は CLI がアプリを自動起動しない）。`recordings/<meeting-id>/manifest.json` と `tracks/*.wav`、`transcripts/<meeting-id>/{live,raw,final,minutes}.json`、`vault-state/<meeting-id>.json`（書き出した内容のハッシュ）、`queue/jobs/*.json`、`models/`（ggml モデル。`AppPaths.modelsDirectory`）、`claude-cwd/`（`claude -p` の空の作業ディレクトリ。計画 05）、`merged/`（計画 02 `SegmentMerger` の出力。`recordings/<meeting-id>/merged/`）、`settings.json`、`automations.json`、`logs/`、`portable-mirror/`（`_autonote/` の写し）、`autonote.sock`
- `settings.json` は `struct Settings: Codable` 一つ。欠けたキーは既定値で埋める（`decodeIfPresent`）。読み書きは `actor SettingsStore`
- 出力フォルダ（Vault）: `Settings.outputFolder`。中の `_autonote/` は `PortableConfigStore` が読み書きし、アプリ領域に写しを持つ（要件書 §9.5）
- ログ: `os.Logger`（サブシステム `com.yutaokoshi.autonote`）＋ `logs/autonote.log` へのテキスト追記。文字起こし本文は書かない

## 6. 並行性とテスト

- Swift 6 strict concurrency。モデルは値型、サービスは `actor`。UI にさわるものだけ `@MainActor`
- 音声コールバック（IOProc、tap のバッファ）はリアルタイム非安全な処理を含めない。ロック・確保・ディスク I/O はしない。固定長リングバッファに書き、別タスクが取り出す（計画 00 の申し送り）
- 停止処理（`AudioDeviceDestroyIOProcID` など）はメインスレッドで同期的に呼ばない
- テスト: Swift Testing（`import Testing`）。ハードウェアと `claude` が要るものはテストにしない。差し替え層のフェイクは `AutoNoteTestSupport` に置き、後処理と保存形式はフェイクで端から端まで自動テストする（要件書 §21）
- フィクスチャ: `Tests/Fixtures/` に 5 分の会議の `manifest.json`、2 トラック分の `[Utterance]` JSON、`MinutesOutput` JSON、期待する会議ファイルと `_index.md` を置く（計画 01 が作る。以後の計画はこれを使う）

## 7. 開発用サブコマンドと E2E（利用者の指示: 実装したら自動で動作確認し、E2E に残す）

- 各計画は `autonote dev <名前>` を足し、`scripts/e2e-check.sh` に項目を追加する。`dev` 配下は利用者向けではないので使い方には出さない
- E2E の項目名は計画番号で付ける: `CURRENT="01.1 render-fixture が golden と一致"`、`CURRENT="02.1 dev record で 5 秒の WAV と manifest"` のように「計画番号.連番 名前」。`16`・`16b`・`M1`・`6b`・`7c` のような番号は使わない。計画 00 の 1〜15b はそのまま。計画 04 が Spikes を消すとき 8・14・15・15b を外す（10 は `tools/whisper.cpp` の確認なので残す）
- E2E から CLI を呼ぶときは計画 01 が足す共通の補助 `AUTONOTE_CLI`（`swift build` 済みの `autonote` のパス。無ければ `.build/debug/autonote`）を使う
- **各計画の最後のタスクは E2E 更新**。後回しにできる 👤 タスク（Apple Silicon 確認など）は最後のタスクの前に置き、見出しに「（後回し可）」と書く
  - 01: `autonote dev render-fixture --out <dir>` フィクスチャから会議ファイルと `_index.md` を一時フォルダに書き、期待ファイルと比較
  - 02: `autonote dev record --seconds 5 --out <dir>` マイクとシステム音を 5 秒録って WAV と manifest を出す（E2E では許可があるときだけ、無ければ SKIP）
  - 03: `autonote dev devices` 接続中の入力デバイス一覧 JSON
  - 04: `autonote dev transcribe <wav> --engine <名前>` と `autonote dev engines`
  - 05: `autonote dev summarize --fake <transcript.json>` フェイクで待ち行列を一周
  - 06: `autonote status` などの本番コマンドをソケット経由で（E2E はアプリを起動してから打つ）
- 各計画の最後のタスクは「E2E を更新し全 PASS を確認してコミット」。実装者はタスク完了前に `scripts/e2e-check.sh`（長い計画では `--quick`）を回す

## 8. 計画 00 からの申し送り（該当計画に必ず入れる）

- 02 の最初のタスク: TCC まとめ確認（`open` 起動、判定は TCC.db の行。システム音声の許可の持続、許可なしの挙動、DictationTranscriber が許可不要なこと）。IOProc は無音時に呼ばれない件を BT 出力でも確認
- 02: 無音検知は最後のコールバックからの経過時間。無音区間は `AudioTimeStamp` から時間で埋める。aggregate に出力デバイスを含めない
- 03: `AudioDeviceID` は保存しない。一致は入力側 `DeviceUID` 完全一致。3.5mm は `BuiltInHeadphoneInputDevice` の追加・削除。項目 5・10（VPIO、組み直し）は未実施なので、該当機能は「仮の方式＋👤 実機確認タスク」で書く
- 04: 発話の区切り（`finalize(through:)` / `.frequentFinalization` / 沈黙）を決めるタスクを置く。SpeechTranscriber は `isAvailable && !supportedLocales.isEmpty` で判定。Apple Silicon の確認は 👤 タスク（計画 00 Task 8 の内容を引き継ぐ。AppleSpeechProbe の transcriber live/file 経路を足してから）。whisper は `max-context 0` と繰り返し除去。Intel の既定: リアルタイム Dictation、確定版 large-v3-turbo、whisper リアルタイムなら small
- 05: `claude -p` のコマンドラインは要件書 §8.1 を一字一句使う。`project` での長い会議の確認を最初の 👤 タスクに。成功判定は `structured_output`・`is_error`・`subtype`。分割閾値 200k は仮
- 06: Bundle ID と証明書名の一本化（`scripts/config.sh`。計画 00 最終レビューの M4）。辞書ファイルの外部編集の読み直し（§7.2）は 06 が担当

## 8b. Lead の裁定（草稿の突き合わせで決めたこと。2026-10-26）

- 猶予中の「取り消す」は出さない。要件書 §15.1 と §5.9 が矛盾しており §5.9 を採る。計画 06 の最初のタスクで要件書 §15.1 を「カウントダウン中のみ」に直す
- `RecordingSession` の状態は計画 02 の `func events() -> AsyncStream<RecordingEvent>` 一本で公開する。**呼ぶたびに新しい購読を返し、全購読者に同じ事象を流す**（プロパティではなく関数。1 人しか読めない `AsyncStream` を共有しない）。計画 03・05・06 はこれを購読する。計画 05 の `RecordingActivity`（録音中かどうかの `AsyncStream<Bool>`。一時停止中・猶予中も「録音中」）は 05 側のアダプタで `events()` から作る
- 確定版の組み立て（トラックごとの `BatchTranscriber` → `startOffset` 加算 → `TranscriptFinalizer` → `raw.json` / `final.json`）は計画 04 の `FinalTranscriptionRunner` が一括で行い、計画 05 の `TranscribeStage` はそれを呼ぶだけにする（05 が 01 の部品で組み直さない）。署名: `struct FinalTranscriptionRunner: Sendable { init(transcriber: any BatchTranscriber, engineName: String, paths: AppPaths, gate: BatchGate); func run(manifest: Manifest, dictionary: DictionaryFile, fillerRemoval: Bool, progress: @Sendable @escaping (Double) -> Void) async throws -> FinalTranscriptResult }`
- 録音中の確定版文字起こしは**取り消さず一時停止する**: 計画 04 の `actor BatchGate { nonisolated var isPaused: Bool { get }; func pause(); func resume(); func waitIfPaused() async }` を `WhisperBatchTranscriber` がセグメント境界で見る。計画 05 の `PostProcessingQueue` は `RecordingActivity` が true の間 `gate.pause()`、false で `gate.resume()` を呼ぶだけ。タスクの取り消しは使わない。**`gate` は `PostProcessingQueue` の init の必須引数**（`PostProcessingQueue(paths:stages:activity:gate:)`。既定値を付けない。渡し忘れを防ぐため）
- 一時停止・ブックマークの印は、計画 04 の `LiveFeed` が話者 `.unknown` の `Utterance` として流し、判定は `LiveFeed.isMarker(_ u: Utterance) -> Bool`（静的関数）で行う。計画 01 の `Utterance` には項目を足さない
- 待ち行列の再実行は 2 種類: 失敗したジョブ（`QueueSnapshot` 上で failed）は計画 05 の `public func retry(_ id: MeetingID) async`（失敗した段階から再実行）、完了した会議の議事録のやり直しは `regenerate(_ id: MeetingID) async`（`generation` +1 で `summarize` から）。計画 06 の `UserNoticeAction.retry(id)` と「再実行」ボタンは、ジョブが failed なら `retry`、それ以外は `regenerate` に振る
- `Job.generation` は再生成のときだけでなく、利用上限（rate limit）後の自動再試行でも +1 する（Automations の二重実行防止キーがそのたびに変わる）
- 「議事録生成」「文字起こしのみ」の完了通知は、計画 06 の `NoticeRelay` が `rows: [MeetingRow]` の `status` の変化（→ `minutes_generated` / `transcript_only`）で判定する。成功したジョブは `QueueSnapshot` から消えるので、ジョブの有無では判定しない。`QueueSnapshot` の項目には `summaryFailure` と `awaitingConfirmation` を含め、06 の画面用データはそれを落とさない
- 要件書 §7.3（用語登録のサジェスト UI）は要件書 §18 のとおり二期目。どの計画も実装しない。`MinutesOutput.suggested_terms` は計画 01 の型に持ち、計画 05 は `minutes.json` に保存するだけ
- 計画をまたぐ配線の担当は**計画 06 の Task 13（`AppEnvironment.make`）**。そこで次をつなぐ: (1) `RecordingSession.events()` の `.stopped(manifest, reason)` → `PostProcessingQueue.enqueue(manifest.id)`（`tooShort` は enqueue せず通知）、(2) `AudioImporter` の完了と `CrashRecovery` の「はい」 → `enqueue`、(3) `RecordingSession.audio(for: Track)` → `LiveFeed` → `live.json`、(4) 起動時の `PortableConfigStore.sync()` と出力先変更時の組み直し、(5) `AutomationsStage` の登録。組み立て関数は各計画が用意する: 02 `RecordingSession.live(paths: AppPaths, settings: Settings, clock: any HostClock = MachHostClock())`（`MeetingClock` は会議ごとに `start` で作るので渡さない）、04 `LiveFeed.make(settings:catalog:factory:dictionary:liveJSON:)`、05 `PostProcessingQueue(paths:stages:activity:)`（`gate:` と `clock:` は既定値つき）と `public func enqueue(_ id: MeetingID) async`
- 議事録の完了・失敗の通知（`minutesGenerated` / `transcriptOnly` / `claudeNotLoggedIn` / `overwriteConfirmation`）は計画 06 の `NoticeRelay.notices(previous:current:rows:)` が `QueueSnapshot` の差分から出す。計画 05 の段階と `AutomationsStage` は通知を出さない（通知の出口を 1 か所にする）
- `batch/<meeting-id>/` は使わない（計画 04 の runner が raw / final を直接書き、分割単位の途中再開は持たない）。§5 の記述から除く
- 計画 02 の Task 1 だけは例外として `Sources/AutoNoteApp/DevChecks.swift`（TCC 確認用の一時メニュー）を足してよい。計画 06 の Task 13 で削除する
- 分割 WAV の結合（計画 02 `SegmentMerger`）は一時停止の位置でファイルを分け、計画 04 の `TimelineMapper` が時刻の飛びを扱う。結合は停止時ではなく文字起こしの直前に 04 が行う
- 片方の音源が開始に失敗したら残りで録音を続ける。マイク許可が無いときだけ録音を始めない（計画 02）
- 計画 05 の Task 14 の任意 👤（Swift 実装から実の `claude` を 1 回呼ぶ）は残す。費用は 1 回分
- 一時停止・ブックマークの印はリアルタイム表示では `Utterance`（話者 `.unknown`、`isMarker`）として流す（計画 04）。計画 06 はこれを表示する

## 8c. 計画 01 の実装で確定した変更（2026-10-26。以後の計画はこれに従う）

- protocol 宣言のファイル名は `Audio/AudioProtocols.swift`・`Transcription/TranscriptionProtocols.swift`・`Minutes/MinutesProtocols.swift`（SwiftPM は同じターゲット内で同名の `Protocols.swift` を許さない）。計画 02〜05 の `Protocols.swift` という記述はこれに読み替える
- §3 のすべてのモデル型は `Equatable` と `Hashable` も持つ（`Transcript` を含む）
- `AutoNoteJSON` の日付は ISO-8601 のミリ秒付き（`2026-10-24T05:00:00.000Z`）で書き、読みはミリ秒の有無どちらも受ける。保存した `Date` はミリ秒精度になるので、テストで等値比較するときは保存→読込の往復後の値と比べる
- 保存する型（`Manifest` `Settings` `Job` など）に後から項目を足すときは optional か `decodeIfPresent` にする。必須項目を足すと古いファイルが読めなくなり、`ManifestStore.all()` から黙って消える
- `VaultWriter` と `PortableConfigStore` は出力フォルダごとに 1 インスタンスを共有する（計画 05 と 06 が別々に作らない。actor 内でしか排他しない）。配線は計画 06 Task 13 の `AppEnvironment.make`
- `PortableConfigStore` は `portable-mirror/.sync-state.json`（`output_folder`、ファイルごとの `last_synced_sha256`）で同期状態を持つ。写しが前回の同期から変わっていなければ Vault を正とし、出力フォルダを付け替えたときは Vault 側の既存ファイルを残す。無効時に書いた既定値は同期済みとして記録される
- `TranscriptMarkdown.linkTarget`: `floor(start) ≤ t` の発話のうち、`start ≤ t ≤ (end ?? start)` で t を含む最後の発話を優先し、無ければ最後の候補
- `FrontmatterTemplate`: 自由文の変数（`title` `device` `transcript_engine` と未知の変数）は厳格に引用符で囲む（英数字・空白・`_` `-` `.` 以外を含む、数字・`-` `.` で始まる、真偽・null 語、のとき）。構造化された値（`date` `start` `end` `duration_min` `status` `autonote_id` `autonote` `language`）は従来規則
- `HintBudget.fit(_:limit:separator: String = ", ")`。計画 04 は `separator: "、"` を渡す
- `AutoNoteJSON.compactEncoder()`（1 行、キー順固定、ミリ秒付き日付）を計画 02 Task 14 が足し、`dev` サブコマンドの 1 行 JSON 出力に使う
- `SettingsStore.init(paths:timeZone: TimeZone = .current)`。`autonote` CLI は `AutoNoteTestSupport` に依存する（`dev render-fixture` のため）

## 8d. 計画 02 の実装で確定した変更（2026-10-26。以後の計画はこれに従う）

- `RecordingSession.events()` の購読はアプリ寿命。`.stopped` でストリームは終わらず、購読者の取り消しだけで外れる（計画 03・06 は 1 回購読すればよい）。`audio(for:)` は会議ごとで、`stop` と `start` 失敗時に終わる
- `RecordingSession.init` は末尾に `timeZone: TimeZone = .current` を持つ（`MeetingID.make` に渡す）。`AudioImporter.init` も同じ。`startedAt` / `endedAt` はミリ秒に切り詰めて保存する（返す manifest と保存した manifest が等しい）
- `RecordingSession.tick()` は `stop` を inline で呼ばない（ticker の自己待ちを防ぐ）。停止が要るときは `Task { stop(reason:) }` を起こす。`resume()` は失敗しても state が `.recording` に戻ることがある（開けたトラックだけで続く）。writer の失敗は `.sourceFailed(track, …)` を 1 回出して `silenceWarning = true`
- `ProcessTapSource.init` に `startTimeout: Duration = .seconds(10)`、`MicrophoneSource.init` に `stopTimeout: Duration = .seconds(5)`。`AudioSourceError` に `timedOut(call: String)` を追加。許可未応答などで開始が止まっても `RecordingSession.start` は約 10 秒で戻り、システム音は `.sourceFailed(.system, …)` としてマイクだけで続く
- `AggregateLayout` の既定は `.tapOnly` のまま（許可ありでの受信は未測定、利用者待ち）。`withOutputClock` は出力機器に入力がある場合にタップ音声を捨てる既知の問題があり、既定を変える前に直す
- `SegmentMerger` の出力 `merged/<track>-<n>.wav` は返り値の `[TrackFile]` だけを信じる（ディレクトリ走査はしない。前回の残骸が残りうる）
- `AutoNoteJSON.compactEncoder()`（1 行 JSON、snake_case、sortedKeys、スラッシュを逃がさない）を CLI の出力に使う。`RecordingReport` の `peak_dbfs` は −∞ のとき明示の `null`
- `autonote dev record` は `--tap-layout tapOnly|withOutputClock` を持つ。E2E 02.1 は `sourceFailed(system)` のとき（許可未応答）SKIP、40 秒ハングは FAIL
- `CrashRecovery.recover` は壊れたヘッダのファイルを除外して続ける（throw しない）。生きているファイルは全部 `repairHeader` して `durationSeconds` を埋め直す
- TestSupport の fake は `public` + 明示の `public init`。`FakeDiskSpace(bytes:)`（`calls`・`error` あり）、`FakeAudioSourceFactory`（`microphoneUIDs`・`nextMicrophone`）、`FakeTapHardware`（`startDelay`・`teardownDelay`）、`FakeMicrophoneEngine`、`FakeDeviceLookup(devices:)`、`FakeMicrophonePermission(_:)`

## 8e. 計画 03 の実装で確定した変更（2026-10-26。以後の計画はこれに従う）

- snake_case の JSON で `xxxUID` という名前のプロパティを持つ型（`DeviceIdentity`、`RegisteredDevice`、`RecorderSnapshot.meetingID`）は、`CodingKeys` の raw value を `xxxUid` / `meetingId` にする（`AutoNoteJSON` の `convertFromSnakeCase` は JSON キーを camelCase にしてから照合するため）。ファイル上のキーは `device_uid` / `model_uid` / `meeting_id` のまま
- `TimerScheduling.sleep(seconds:)` は `async throws`。呼び出し側のタスクがキャンセルされたら内部のタイマーを取り消して `CancellationError` を投げる（`Task.sleep` と同じ）。`MicrophoneReattacher.reattach(uid:)` はキャンセルで `.failed` を返す
- `_autonote/devices.json` の既定は `{"version":1,"devices":[]}`（`PortableDefaults.standard[.devices]`）。トップレベル `[]` も空として読め、次の保存で新形式になる。読み込み・退避の I/O エラー時はレジストリが空の read-only 状態になり（`match` は `.unknown`、変更系は `DeviceRegistryError.storageUnavailable`）、ファイルを上書きしない。壊れた JSON は `<data>/devices.json.corrupt-<yyyyMMdd-HHmmss>[-n]` へ一度だけ退避する（同じ内容は再退避しない）
- `DeviceMonitor.events()` は複数購読可。各購読者は最初に接続中の候補ごとの `.present(_, .launch)` を 1 回受け取る。復帰の抑止窓は `didWake` で開く（`willSleep` と `didWake` の間の切断は `.removed` として出る）
- `AutoRecordCoordinator` は全操作を FIFO ゲートで直列化する（`handle(event)`・`handle(action)`・`manualStart`・`stop(reason:)`・`pause`・`resume`・`cancelCountdown`・`setLanguage`・`bookmark`・タイマー・自己停止・再接続完了）。`snapshots()` は `async`。`stop` は進行中の `start` を待ってから止める（キャンセルするのは再接続タスクだけ）。`stop(reason: StopReason = .manual)`。登録の問いに機材を外した後で答えても、記憶した identity で登録・無視する
- `RecordingSessionControl.selfStops()` は `async`。自分が要求した `StopReason` と同じ `.stopped` だけ落とし、それ以外（ディスク不足など）は自己停止として流す。`stop` の重ね呼びは禁止（Coordinator が直列化する）
- 状態機械: 一時停止中に機材が外れて猶予中に戻った場合は一時停止のまま（再開は利用者の操作）。`AutoRecordConfig` のフィールドは `private(set)`（`init` で丸める）
- `CoreAudioDeviceLookup.transport` は `CoreAudioHardware.transport(coreAudio:)` に委譲（`AutoAggregate` も `aggregate`）
- CLI: `autonote dev auto-record`・`autonote dev devices [--watch]`、機材行の JSON は `Sources/autonote/DeviceJSON.swift`（`DeviceLine`）で共有。E2E 03.1〜03.3（`CHECKS` 末尾）。`run_timeout` はコマンドをバックグラウンドで起動するので stdin を渡す確認はパイプ全体を背景化して自前で待つ。`dev auto-record` の `quit`・stdin EOF・SIGINT は同じ経路（ゲート経由の `cancelCountdown()` → `stop(reason: .appTerminating)` → `run()` の取り消し → exit 0）で、状態を見て分岐しない
- `DeviceRegistry` の変更系と `reload()` は内部ゲートで直列化され、`reload()` は読み込み完了まで既存の一覧を保つ（計画 06 の設定画面が直接呼んでも安全）。Y6 の遅延読み込みは無し: `entries()` の前に `reload()` を呼ぶ
- 猶予中の復帰判定: UID 一致・登録項目 ID 一致に加え、USB で方式・型番（nil と `0 0` を除く）・名前が起点と同じ機材も起点の復帰とみなす（ドックの別ポートに挿し直した場合）
- `AutoRecordCoordinator` のゲートは再入不可: `UserNotifier` / `RecordingControl` の実装から同期的に Coordinator を呼び返さない（UI のコールバックは別 Task で）
- 利用者待ち: 計画 03 Task 10 Step 4〜7（Shokz / 3.5mm / USB の実機確認、スパイク項目 10）

## 9. Global Constraints（各計画の同名節にそのまま写す）

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
