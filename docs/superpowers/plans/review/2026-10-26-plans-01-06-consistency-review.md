# 計画 01〜06 整合性レビュー（2026-10-26）

対象: `docs/superpowers/plans/2026-10-25-autonote-0{1..6}-*.md`（計 4,754 行）、拘束文書 `2026-10-25-autonote-plans-overview.md`（以下 overview。§8b の Lead 裁定を含む）、要件書 `docs/superpowers/specs/2026-10-24-autonote-design.md`、書式規約 `superpowers/skills/writing-plans/SKILL.md`。
行番号は各計画ファイルの行（`L123`）。「T4」は Task 4。

## 1. 要約

- A（Consumes⇔Produces の不一致）: **47 件**。B: 抜け **9 件**（うち 1 件は要件書上も任意）、重複 **10 件**。C（overview との矛盾）: **8 件**。D（書式違反）: **3 件**。E（実行順の破れ）: **4 件**。
- 重い不整合 3 つ:
  1. **計画 05 が計画 01 の実 API をほぼ見ずに書かれている。** `Job`/`StageContext`/`StageName` を T2 で再定義して 01 T4 と衝突させ、存在しない名前を約 15 個呼んでいる（`VaultWriter`・`MeetingDocument`・`MeetingFileName`・`Settings` の項目・各 Store）。さらに §8b に反して確定版文字起こしを自前で組み直しており、04 の `FinalTranscription` は呼ばない。録音中の停止も 04 の `BatchGate` を使わず、タスクの取り消しで別に実装している。
  2. **`RecordingSession.events` が 1 人しか読めない `AsyncStream` プロパティになっている（02 T10 L565）。** 03・05・06 の 3 者が購読するので、実行時に取り合いになる。§8b は `events()`（購読ごとに新しいストリーム）を求めている。06 が想定する `RecordingEvent` の case も、02 の定義とほぼ全部違う。
  3. **計画 06 の「想定 API 表」（L44〜62）が 01〜05 の実定義とほぼ全行で食い違っている。** `Settings.shortcuts` の型を変えてしまい、`TranscriptKind` も二重に定義している。`UserNotice` を宣言している計画は無い（03 には `DeviceNotice` しかない）。Automations の重複防止キーを `job.id` にしているが、05 の再生成は新しい job を作らないので、`minutes_generated` が二度と発火しない。
- 加えて、録音停止・取り込み・クラッシュ復旧の後に待ち行列へ `enqueue` する担当計画が無い。録音しても議事録まで流れない。

## 2. A: Consumes ⇔ Produces の不一致

直す側の既定は「定義する側（overview §4）に合わせる」。§8b の裁定と overview §3 の明記がある場合は、そちらを優先する。

| # | 使う側 | 定義側 | 何が違うか | 直す側と直し方 |
|---|---|---|---|---|
| 1 | 計画 05 T2 L101-107 の `StageName`/`Job`/`StageState`/`StageContext`/`JobStore` | 計画 01 T4 L206-209 の `StageName`/`Job`/`JobState`/`StageContext` | 05 が再定義している。フィールドも違う（05 は `meetingID`・`stages:[StageRecord]`・`transcriptEngine`・`summaryFailure`・`vaultFile`・`overwriteApproved`、01 は `id`・`meeting`・`stages:[String]`・`completedStages`・`state`・`attempts`・`lastError`・`notBefore`）。01 のテスト `fakeStageRunsAndJobRoundTrips` が壊れる | **05**: T2 の型定義を消して 01 の型を使う。05 が要るフィールド（`transcriptEngine`・`summaryFailure`・`overwriteApproved`・下の #36 の `generation`）は、overview §3 に先に足してから 01 T4 に入れる |
| 2 | 計画 05 L43 の `AppPaths.recordingDirectory(for:)`・`transcriptsDirectory(for:)`・`jobsDirectory`（`AppPaths+Minutes`） | 計画 01 T3 の `meetingDirectory(_:)`・`transcriptsDirectory(_:)`・`queueJobsDirectory` | 名前もラベルも違い、拡張で二重に定義している | **05**: 01 の名前を使い、拡張を消す |
| 3 | 計画 05 L43 の `ManifestStore.allIDs()` | 計画 01 T3 の `ManifestStore.all()` | 名前と戻り値が違う | **05** |
| 4 | 計画 05 L43 の `SettingsStore.current()` | 計画 01 T3 の `SettingsStore.load()` | 名前が違う | **05** |
| 5 | 計画 05 L43 の `PortableConfigStore.prompt()`/`dictionary()` | 計画 01 T12 の `read(_: PortableFile) -> Data?` | 専用のゲッタは無い | **05**: `read(.prompt)` を使い、デコードは 05 側で行う |
| 6 | 計画 05 L44・計画 06 L52 想定表の `Settings.outputFolder: URL?` | 計画 01 T3 の `outputFolder: String?` | 型が違う | **05・06**: `String?` を使い、URL への変換は使う側で行う |
| 7 | 計画 05 L44・計画 06 T15 の `audioRetentionDays: Int?`（nil で削除しない） | 計画 01 T3 の `Int`（既定 30、0 で削除しない。overview §3 L88） | 「削除しない」の表し方が違う | **05・06**: 0 で判定する |
| 8 | 計画 05 L44 の `fillerRemovalEnabled` | 計画 01 T3 の `fillerRemoval` | 名前が違う | **05** |
| 9 | 計画 05 L45 の `TranscriptMerger.merge(mic:system:)` | 計画 01 T7 の `merge(_:source:)` | 引数が違う | **05**: #14 で呼び出し自体が消える |
| 10 | 計画 05 L46 の `MeetingDocument(manifest:transcript:minutes:status:transcriptEngine:)` | 計画 01 T9 の `(manifest:transcript:minutes:frontmatter:appVersion:timeZone:)` | 引数が違う | **05** |
| 11 | 計画 05 L46・T11 の `MeetingFileName.make(start:title:existing:)` | 計画 01 T8 の `titled`/`untitled`/`yearFolder`/`unique`/`isUntitled` | `make` は無い | **05** |
| 12 | 計画 05 L46・T11 の `VaultWriter(outputFolder:)`、`write(_:to:) -> VaultFileRecord`、`isModified` | 計画 01 T11 の `VaultWriter(outputFolder:paths:now:)`、`write(_:policy:renameToMatchTitle:) -> VaultWriteOutcome{written, conflict}`、`record(for:)` | init、書き込み、編集検知のどれも違う | **05**: 01 の `policy` と `.conflict` で「編集済みの確認」を表す。`overwriteApproved` は `policy: .force` に写す |
| 13 | 計画 05 L46・T12 の `VaultScanner.scan -> [ScannedMeeting]`、`IndexFile.rebuild(outputFolder:)` | 計画 01 T10 の `scan(outputFolder:) -> [IndexEntry]` と 01 T11 の `VaultWriter.rebuildIndex()` | 型と担当が違う | **05**: `UpdateIndexStage` は `rebuildIndex()` を呼ぶだけにする |
| 14 | 計画 05 T9 L522-531 の `TranscribeStage`（区切りごとに結合・重複除去・置換・フィラー除去を自前で行う） | §8b と計画 04 T11 L678 の `FinalTranscription.run(manifest:dictionary:fillerRemoval:progress:)` | §8b は「05 は呼ぶだけ」と決めている | **05**: T9 を書き直し、04 の runner を呼ぶ。失敗したときにリアルタイム版で代替する処理だけを 05 に残す |
| 15 | overview §8b の `FinalTranscriptionRunner` | 計画 04 T11 L678 の `FinalTranscription` | 名前が違う | **04**: overview の名前に改める（overview が優先） |
| 16 | 計画 05 T8 L478-（録音開始で transcribe を取り消す） | 計画 04 T5 L323 の `BatchGate`（「05 が `pause()`/`resume()` を呼ぶ」） | 止め方が違い、`BatchGate` を使う人がいない | **overview で決める**。提案は `BatchGate`（途中の結果が残り、§13 の「止める」に近い）。05 T8 は録音状態を見て `gate.pause/resume` を呼ぶ形に直す |
| 17 | 計画 03 T7 L450・計画 05・計画 06 L53 の `events()`（複数の購読者） | 計画 02 T10 L565 の `nonisolated let events: AsyncStream<RecordingEvent>` | 1 人しか読めないストリームのプロパティになっている | **02**: `func events() -> AsyncStream<RecordingEvent>` にして、呼ぶたびに新しい continuation を登録し、全員へ流す |
| 18 | 計画 06 L53 の `RecordingEvent`（`started(MeetingID)`・`stopped(MeetingID, MeetingStatus)`・`paused(TimelineTime)`・`silence(Track)`・`diskLow`・`diskCritical`） | 計画 02 T10 の `started`・`paused`・`resumed`・`bookmarked`・`silenceWarning(SilenceWarning)`・`diskSpaceLow(availableBytes:)`・`sourceFailed`・`microphoneDetached/Attached`・`stopped(Manifest, StopReason)` | case も付随値も違う | **06**: 02 の case に合わせ、`NoticeRelay`（T12）の対応表も直す。`diskCritical` に当たるものは 02 では `stop(.diskFull)` |
| 19 | 計画 05 L48 の `RecordingActivity`（「02 が準拠するか、06 のアダプタ」） | §8b（05 側のアダプタで `events()` から作る） | 誰が作るかが違う | **05**: アダプタを 05 のタスクに入れる |
| 20 | 計画 02 T13 L705・計画 04 T11 L694 の、取り込み音声＝`.system`・`tracks/import.wav` | overview §3 L87 の `Track.mic`、計画 01 T13 のフィクスチャ `tracks/import-000.wav`（mic） | トラック種別もファイル名も違う | **02・04**: `Track.mic` にする。ファイル名は overview で 1 つに決める（提案は 01 のフィクスチャに合わせた `import-000.wav`） |
| 21 | overview §3 L88 と計画 06 L816 の `summarizerKind`（06 は `String`） | 計画 01 T3 L142 の `summarizer: SummarizerKind` | 名前と型が違う | **01**: `summarizerKind: SummarizerKind` に改名する。**06**: enum を使う |
| 22 | overview §3 L88 の既定値（開始/停止 ⌃⌥R、一時停止 ⌃⌥P） | 計画 01 T3 L150 の `toggleRecording nil`・`togglePause nil` | 既定値が違う | **01**: `"ctrl+option+r"`・`"ctrl+option+p"` にする |
| 23 | 計画 06 T10 L563-564 の `ShortcutBindings`/`KeyCombo` で `Settings.shortcuts` を置き換える | 計画 01 T3 の `Shortcuts{bookmark/toggleRecording/togglePause: String?}` | 06 が 01 の型を変えてしまう | **06**: 保存形式は 01 の文字列のまま残し、`KeyCombo(parsing:)`/`description` で変換する。`ShortcutBindings` は表示用の型にとどめる |
| 24 | 計画 06 T10 L564 の `consentNoticeShown` を足す | 計画 01 T3 で既に定義している | 二重に定義している | **06**: 削除する |
| 25 | 計画 06 L808・L821 の `Settings.graceSeconds`（1…600） | 計画 01 T3 の `disconnectGraceSeconds`、計画 03 T5 L308 の clamp（0…300） | 名前も範囲も違う | **06**: 名前を `disconnectGraceSeconds` にする。範囲は overview で 1 つに決め（提案は 03 の 0…300）、06 は 03 の `AutoRecordConfig` の clamp を使う |
| 26 | 計画 06 L823 の `batchEngine`/`batchModel` | 計画 01 T3 の `finalEngine`/`finalModel` | 名前が違う | **06** |
| 27 | 計画 06 L823 の `EngineCatalog.engines()`（`isAvailable`） | 計画 04 T4 の `EngineCatalog.entries(role:language:)`、`EngineChoice.fromSettings` | 名前と引数が違う | **06**: 04 の API と、設定に書く文字列（`dictation`/`speech`/`whisper`）を使う |
| 28 | 計画 06 L57・T12 L668 の `UserNotifier.post(UserNotice)`・`withdraw(id:)`、10 種の `UserNotice`/`UserNoticeAction` | 計画 03 T6 L399-401 の `post(DeviceNotice)`・`dismiss(id:)`、`NoticeAction`（機材の分だけ） | overview §3 は「03 が全計画分の `UserNotice` を宣言する」と決めているが、03 が従っていない | **03**: `UserNotice`/`UserNoticeAction` を全 case 込みで宣言する（06 T12 の表の case）。メソッド名は `withdraw` か `dismiss` のどちらかに決める。**06** は 03 の名前に合わせる |
| 29 | 計画 06 L55-56・T7 L372 の `RecorderSnapshot`、`current()`/`snapshots()`/`stop()`/`bookmark(note:)`/`setLanguage`/`handle(UserNoticeAction)` | 計画 03 T8 の `AutoRecordStatus`、`status()`/`statusUpdates()`/`manualStop()`/`respondToRegistration`、bookmark と setLanguage は無い | 名前が違い、機能も足りない | **06**: 03 の名前に合わせる。**03**: `bookmark(note:)` と `setLanguage(_:)` を Coordinator に足す（03 L7 は「必ず Coordinator を通す」と書いている） |
| 30 | 計画 06 L52・T14 L782 の `VaultWriter.hasExternalChanges`・`rewriteMinutes` | 計画 01 T11 には無い | 存在しない API を呼んでいる | **06**: T7 の `MeetingsPort` アダプタで組み立てる。`minutes.json` を保存したら `write(policy: .refuseIfModified)` を呼び、`.conflict` が返れば「外部で編集あり」と判断する。01 は変えない |
| 31 | 計画 06 T7 L375 の `public enum TranscriptKind { live, final }` | 計画 01 T3 の `TranscriptKind {live, raw, final}` | 同じ名前で二重に定義している（コンパイルエラーになる） | **06**: 削除して 01 の型を使う |
| 32 | 計画 06 L375 の `interrupted()`（`CrashRecovery.interrupted()`） | 計画 02 T12 の `findInterrupted(excluding:)`・`recover`・`discard` | 名前が違い、引数の除外指定が抜けている | **06** |
| 33 | 計画 06 L375 の `importAudio(_:startedAt:) -> MeetingID`（`AudioImporter` を actor と想定） | 計画 02 T13 の `importFile(_:startedAt:language:progress:) -> Manifest` | 引数と戻り値が違う | **06** |
| 34 | 計画 06 の想定表の `LiveFeed.updates()` | 計画 04 T10 の `start(...) -> AsyncStream<[Utterance]>` | 名前が違う | **06** |
| 35 | 計画 06 の想定表の `QueueJobSummary`・`retry` | 計画 05 の `QueueSnapshot{jobs:[JobProgress], pausedForRecording}`・`rerun(_:from:)` | 名前が違う | **06** |
| 36 | 計画 06 T4 L256 の `job.outcome`・`job.vaultFile`（URL）・`job.minutesFile`・`job.id`（再生成で新しくなる前提） | 計画 05 T2 の `Job`（`outcome` と `minutesFile` は無い、`vaultFile` は `VaultFileRecord?`）、05 T12 の `regenerate`（job を使い回す） | フィールドが無いうえ、再生成でキーが変わらず `minutes_generated` が二度と発火しない | **overview §3**: `Job` に `generation: Int` を足し（再生成で +1）、結果の種別は `MeetingStatus` から引く。**06**: 重複防止キーを `"\(meeting):\(generation)"` にし、パスは `AppPaths.minutesFile` と 01 の `record(for:)` から取る |
| 37 | 計画 06 の想定表の `DeviceRegistry(uid:)` | 計画 03 T4 の `DeviceRegistry` | init が違う | **06** |
| 38 | 計画 06 T16 L864・L870 の `Tests/Fixtures/manifest.json` | 計画 01 T13 の `Tests/Fixtures/meetings/<id>/manifest.json` | パスが違う | **06** |
| 39 | 計画 04 L43・L555 の `autonote_bin()` | 計画 01 T14 L776 の変数 `AUTONOTE_CLI` | E2E の補助関数は存在しない | **04**: `AUTONOTE_CLI` を使う |
| 40 | 計画 03 L58・L93・L109 の「aggregate の UID は `com.yutaokoshi.autonote.` で始まる」（自分の aggregate を機材一覧から除くため） | 計画 02 T8 L421 の UID（新しい UUID だけ） | 接頭辞が無いので、03 が自分の aggregate を機材と誤認する | **02**: UID を `com.yutaokoshi.autonote.<UUID>` にする。overview §8 にも書く |
| 41 | 計画 03 L89 の `DeviceRef.transport "Bluetooth"` | 計画 01 T2 L82・L707 のサンプル `"bluetooth"` | 大文字と小文字が違う | **03**: 01 に合わせて小文字にする。値の一覧は overview §3 に書く |
| 42 | 計画 02 L51 の `Audio/AudioSource.swift`、T2 L131 の `FakeAudioSource.swift` | 計画 01 T4 の `Audio/Protocols.swift`、`Fakes.swift` | protocol とフェイクを別のファイルに二重に置く | **02**: 01 のファイルを修正（Modify）する |
| 43 | 計画 05 T9 の `fallbackSuffix "（…代替）"` | 計画 01 T2 の `Transcript.fallbackEngineLabel(live:)`「（…代用）」 | 文言も関数も違う | **05**: 01 の関数を使う |
| 44 | 計画 06 T10 L558・L616 の `LiveTranscriptBuffer.add(Bookmark)`・`addPause(at:)` | §8b L167 と計画 04 T10（印は `LiveFeed` が `Utterance` として流す） | 印を 06 が別に組み立てる | **06**: `LiveFeed` の出力を表示するだけにし、`add`・`addPause` を消す |
| 45 | overview §8b L167 の「`Utterance`（…`isMarker`）」 | 計画 04 L628 の `static func LiveFeed.isMarker(_:)`、計画 01 の `Utterance` には該当フィールドが無い | フィールドなのか関数なのか定まらない | **overview**: 「04 の `LiveFeed.isMarker(_:)` で判定する。01 の型は変えない」と書く |
| 46 | 計画 04 T3 の `ModelManager.defaultDirectory(paths)`（root/models） | 計画 01 T3 の `AppPaths`（`models` が無い。overview §5 には `models/` がある） | 定義が無い | **01**: `modelsDirectory` を足す。04 はそれを使う |
| 47 | 計画 03 T10 の「計画 02 の RecordingSession の組み立て関数」 | 計画 02（init と `LiveAudioSourceFactory` しか作らない） | 関数が存在しない | **02**: `RecordingSession.live(paths:manifests:settings:)` を T10 か T14 に足す（06 の `AppEnvironment.make` も同じものを使う） |

（`dev summarize` を `main.swift` から直接呼ぶ件は §4 の C に入れた。）

## 3. B: 要件書 §3〜§17 の担当表

| 要件書 | 担当（計画 N Task k） | 判定 |
|---|---|---|
| §3.1 環境 | overview §9、01 T1 | ✓ |
| §3.2 実装技術 | 01 T1、04 T1（XCFramework） | ✓（Swift 6.2/6.3 の不一致は C-7） |
| §3.3 Intel の性能制約 | 04 T4（機種別の既定）・T6・T13 | ✓ |
| §3.4 署名と権限 | 02 T1（TCC）、06 T1（config.sh） | **抜け**: マイク権限の要求画面（02 は「06 が行う」と書くが、06 に該当タスクが無い） |
| §4 利用の流れ | 各計画の E2E | ✓ |
| §5.1 音源 | 02 T8・T9 | ✓ |
| §5.2 保存形式 | 02 T4・T5 | ✓ |
| §5.3 録音中の表示 | 06 T10・T13 | ✓ |
| §5.4 一時停止 | 02 T10、03 T8、04 T10（印）、06 T10 | **重複**: 印の組み立て（04 `LiveFeed` と 06 `LiveTranscriptBuffer`） |
| §5.5 ブックマーク | 02 T10、06 T13（ショートカット） | 03 の Coordinator に入口が無い（A-29） |
| §5.6 エコー対策 | 01 T7 `EchoDeduplicator`、02 T9（`voiceProcessing`） | **重複**: 重複除去（01 T7 と 05 T9） |
| §5.7 無音検知 | 02 T7・T11、06 T12（通知） | ✓ |
| §5.8 クラッシュ復旧 | 02 T12、06 T7・T13（起動時の確認） | **抜け**: 復旧した会議を待ち行列へ入れる担当 |
| §5.9 状態遷移 | 03 T5・T8、06 T10・T13（`QuitPolicy`） | ✓ |
| §6.1 二段構え | 04 T5〜T7 | ✓ |
| §6.2 エンジン差し替え層 | 04 T4・T8、06 T15 | ✓（設定項目の名前は A-26・A-27） |
| §6.3 リアルタイムの動作 | 04 T7・T9・T10 | **抜け**: 配線の担当（`RecordingSession.audio(for:)` → `LiveFeed`、エンジンの解決、会議ごとの `live.json`）。06 は `LiveFeedPort(feed:)` のアダプタしか書いていない |
| §6.4 確定版の動作 | 04 T11、01 T7、05 T9 | **重複**: 01 `TranscriptFinalizer`、04 `FinalTranscription`、05 `TranscribeStage`（A-14） |
| §6.5 フィラー除去 | 01 T6、04 T11、05 T9 | **重複**（同上） |
| §7.1 辞書の役割 | 01 T5、04 T5・T7・T10 | ✓ |
| §7.2 形式と置き場所 | 01 T5・T12、06（外部編集の読み直し。overview §8 の申し送り） | ✓（06 の記述は薄い） |
| §7.3 用語のサジェスト（任意） | なし | **抜け**（要件書上も任意。二期目に回すと明記すればよい） |
| §8.1 呼び出し方 | 05 T1・T5・T6 | **抜け**: 「未ログインなら通知する」に対応する `UserNotice` の case |
| §8.2 出力スキーマ | 01 T2 `MinutesOutput`、05 T6 | ✓ |
| §8.3 プロンプト | 05 T3・T4、01 T12 | ✓ |
| §8.4 失敗時 | 05 T10〜T12、01 T11 | **重複**: 名前が無題かどうかの判定と編集検知（01 T8・T11 と 05 T11） |
| §8.5 API キー方式 | 01 T3（種別）、05 `SummarizerFactory` | ✓ |
| §9.1 フォルダ構成 | 01 T8・T11、05 T11 | **重複**: 書き出しの記録（01 の vault-state と 05 の `Job.vaultFile`） |
| §9.2 会議ファイル | 01 T8・T9 | ✓ |
| §9.3 `_index.md` | 01 T10、05 T12 | ✓（A-13） |
| §9.4 編集との共存 | 01 T11、05 T11、06 T14 | **抜け**: アプリで議事録を編集して書き戻す処理（06 は 01 にあると想定しているが無い。A-30） |
| §9.5 設定の置き場所 | 01 T12、03 T4 | **抜け**: 起動時の `PortableConfigStore.sync` と、出力先を変えたときのサービスの組み直し（06 T13 に「計画01〜05のサービスを作る」とあるだけ） |
| §10 取り込み | 02 T13、06 T7・T14 | **抜け**: 取り込み後に `enqueue` する担当 |
| §11.1〜11.6 自動録音 | 03 T1〜T10 | ✓ |
| §12 データ保持と削除 | 05 T13、01 T3・T11、06 T14 | **重複**: 会議の削除（01 `ManifestStore.delete` + `VaultWriter.remove` と 05 `Retention.deleteMeeting`） |
| §13 待ち行列と進捗 | 05 T7・T8、04 T5 `BatchGate` | **重複**: 録音中の停止（A-16）。**抜け**: 録音停止後に自動で `enqueue` する担当（どの計画も `enqueue` を呼ばない） |
| §14 Automations | 06 T2〜T4、05 T12（差し込み口） | ✓（A-36） |
| §15.1 メニューバー | 06 T10・T13 | **抜け**: §8b が決めた要件書 §15.1 の修正が、06 の最初のタスクに無い |
| §15.2 メインウィンドウ | 06 T14 | ✓ |
| §15.3 設定 | 06 T15 | **重複**: ショートカット設定の型（01 と 06。A-23） |
| §16 CLI | 06 T5・T6・T8・T9 | ✓ |
| §17 非機能要件 | 04 T6・T9（遅延と CPU）、02 T11（ディスク） | ✓ |

その他の重複:
- 計画 02 T1 の `DevChecks.swift` は「06 で削除する」と 02 L64 にあるが、**06 に削除の手順が無い**（抜けの 9 件目）。
- `AppPaths` の補助（01 T3 と 05 の `AppPaths+Minutes`）が重複している。
- 代用エンジン名の文言（01 T2 と 05 T9）が重複している。
- E2E の番号 16 を 01（16/16b）と 02（16/17）の両方が使っている。

数え方は次のとおり。
- 抜け 9 件: マイク権限の画面、復旧後の enqueue、リアルタイムの配線、§7.3、未ログインの通知、議事録の書き戻し、起動時の sync と出力先の変更、録音停止後・取り込み後の enqueue（1 件にまとめた）、§15.1 の修正と DevChecks の削除（1 件にまとめた）。
- 重複 10 件: 結合・重複除去・置換・フィラー除去の処理、録音中の停止、印、ショートカット、削除、無題判定と編集検知、Vault への書き出しの記録、AppPaths、E2E の番号、代用エンジン名の文言。

## 4. 計画ごとの C / D / E

### 計画 01
- C-1: E2E の項目名が `16.`・`16b.`（T14 L763・L778・L788）。overview §7 L141 の「`01.1 render-fixture`」の形に従っていない。
- C-7: Tech Stack が Swift 6.2（L9）、04・05 は 6.3。

### 計画 02
- C-1: E2E が 16・17（T14 L733・L740）。番号が 01 と衝突し、§7 の名前の付け方にも反する。
- C-2: T1 で `Sources/AutoNoteApp/DevChecks.swift` を作る（L64・L67）。overview §2 L45 は「各計画は App を触らない」と書いている。理由は妥当（TCC は起動元で判定されるため）だが、overview に例外として書かれていない。
- E: T1 で要件書と Info.plist を変え、以後の計画がそれを前提にする。順番は守られているので問題ない（数えない）。

### 計画 03
- C-1: E2E 項目に番号が無い（T11 L668-669）。
- D-3: T2 の実装手順が一行で、決めた値（transport の値と対応表）が書かれていない。
- E-3: T10 が、02 の作らない「RecordingSession の組み立て関数」を前提にしている（A-47）。

### 計画 04
- C-1: E2E 項目に番号が無い（T8 L555、T12）。
- C-8: 型の大半に `public` が付いていない（`MachineKind` L74 など一部だけ public）。`autonote` CLI ターゲットから呼ぶので、`dev engines`/`dev transcribe` がビルドできない。
- D-1: 最後のタスクが T13 の 👤（Apple Silicon の確認、L746）で、E2E のタスク（T12）が最後になっていない。T13 は T12 より前に移すか、「任意の 👤」として T12 の後の補足節に置く。
- E: T13 Step 7 は 03 の `dev devices` を使う。ブランチの順番からして問題ない（数えない）。

### 計画 05
- C-1: E2E が `M1`・`M2`（T14）。
- C-4: `dev summarize` を `main.swift` から直接振り分けていて（L761・L782）、01 T14 の `DevCommands.run` を通っていない。
- C-5: `claude-cwd/` と `batch/` が overview §5 の保存場所に無い。
- C-8: 型に `public` が付いていない（CLI から使う）。
- E-1: 01・04 の実際の名前を見ず、想定の名前で書かれている（A-1〜A-14・A-43）。依存の向きは正しい（01・04 が先）が、内容が先の計画の出力と合っていない。
- T1 と T14 の 👤 はどちらも overview §8・§8b のとおりなので問題ない。

### 計画 06
- C-1: E2E が `0.`（T1）、`6b`、`7c〜7f`（T16 L865）。
- C-3: `willPresent` が `[.banner, .list, .sound]` を返す（T12 L708）。overview §3 は「通知は音なし」と決めている。
- C-6: 最初のタスク（T1 config.sh）が、§8b の「要件書 §15.1 を直す」になっていない。L67 で裁定には触れているが、要件書を書き換える手順が無い。
- D-2: T13 Step 1 の「`AppEnvironment.make`: …計画 01〜05 のサービスを作る」（L732）が未決定のまま。組み立てる順番、使う init、待ち行列への登録（enqueue の配線）、`LiveFeed` の配線、`PortableConfigStore.sync` のどれも書かれていない。
- E-2: T4 L251 が `FakeUserNotifier`（`posted: [UserNotice]`）を 03 にあると想定しているが、03 には無い。
- E-4: T10 L563-564 が 01 の `Settings.swift` を書き換える。順番としては後の計画が前の計画を直すので許されるが、overview §9 の「変えるなら本書を先に直す」に反する。
- L44〜62 の想定 API 表は、ほぼ全行が A に挙げた不一致の元になっている（A-18・A-23〜A-38・A-44）。

## 5. 直し方の指示

### 計画 01
1. T3: `summarizer` を `summarizerKind` に改名する（A-21）。ショートカットの既定を `ctrl+option+r`/`ctrl+option+p` にする（A-22）。`AppPaths.modelsDirectory` を足す（A-46）。
2. T4: overview §3 で `Job` に足す項目（`transcriptEngine`・`summaryFailure`・`overwriteApproved`・`generation`）を入れる（A-1・A-36）。
3. T14: E2E の名前を `01.1 render-fixture` の形に直す。`AUTONOTE_CLI` を他の計画も使う共通の補助として明記する。

### 計画 02
1. T10: `events` を `func events()` にし、購読ごとに新しいストリームを返して全員へ流す。テストに「2 人が購読して両方に届く」を足す（A-17）。
2. T8: aggregate の UID に `com.yutaokoshi.autonote.` を付ける（A-40）。
3. T13: 取り込み音声を `Track.mic` にし、ファイル名を overview の決定に合わせる（A-20）。
4. T2: `AudioSource` と `FakeAudioSource` は 01 のファイルを Modify する（A-42）。
5. T10 か T14: アプリ用の組み立て関数 `RecordingSession.live(...)` を足す（A-47）。
6. T14: E2E を `02.1 …` の形に直す。

### 計画 03
1. T6: `UserNotice`/`UserNoticeAction` を全計画分の case で宣言する（06 T12 の表と、05 の未ログイン通知を含む）。`DeviceNotice` は消すか、その中の case に入れる。`FakeUserNotifier` を TestSupport に置く（A-28・E-2）。
2. T8: Coordinator に `bookmark(note:)` と `setLanguage(_:)` を足す（A-29）。
3. T1: transport の値を小文字にする（A-41）。
4. T11: E2E を `03.1 …` の形に直す。

### 計画 04
1. T11: `FinalTranscription` を `FinalTranscriptionRunner` に改名する（A-15）。
2. T11: 取り込み音声を `Track.mic` として扱う（A-20）。
3. E2E で `autonote_bin()` をやめて `AUTONOTE_CLI` を使い、項目名を `04.1 …` の形にする（A-39・C-1）。
4. CLI から使う型に `public` を付ける（C-8）。
5. T13 の 👤 を最後から外し、E2E のタスクが最後になるようにする（D-1）。

### 計画 05
1. T2: 型の再定義をやめ、01 の `Job` 群と `AppPaths` を使う。`JobStore` だけを残す（A-1・A-2）。
2. 01 の実 API に合わせて書き直す: Store 各種、`Settings` の項目、`MeetingDocument`、`MeetingFileName`、`VaultWriter`（`policy`/`.conflict`）、`rebuildIndex`、`fallbackEngineLabel`（A-3〜A-13・A-43）。
3. T9: `TranscribeStage` を「04 の `FinalTranscriptionRunner` を呼び、失敗したらリアルタイム版で代用する」だけにする（A-14）。
4. T8: overview の決定に従い、`BatchGate` の pause/resume で止める（A-16）。
5. `RecordingActivity` のアダプタを 05 のタスクに入れる（A-19）。
6. T13: 会議の削除は 01 の `ManifestStore.delete` と `VaultWriter.remove` を呼ぶ形にする。
7. T14: `dev summarize` を `DevCommands` 経由にし、E2E を `05.1 …` の形にする。`claude-cwd` と `batch` を overview §5 に足してもらう。型に `public` を付ける。

### 計画 06
1. T1 の前に「要件書 §15.1 の『猶予中』を削る」タスクを置く（C-6）。
2. L44〜62 の想定表を消し、01〜05 を直した後の Produces を写す（A-18・A-23〜A-38）。
3. T7: 二重の `TranscriptKind` を消す。議事録の保存と外部編集の検知は、`MeetingsPort` のアダプタで 01 の API から組み立てる（A-30・A-31）。
4. T10: 01 のショートカットの文字列を変換して使う。`consentNoticeShown` の二重定義を消す。`LiveTranscriptBuffer` から印の組み立てを外す（A-23・A-24・A-44）。
5. T12: `.sound` を外す（C-3）。`UserNotice` は 03 の宣言を使う。
6. T13: `AppEnvironment.make` を具体的に書く。次を手順として入れる。
   - 組み立てる順番
   - 録音停止・取り込み・復旧の後に `enqueue` する配線
   - `audio(for:)` → `LiveFeed` → `live.json` の配線
   - 起動時の `PortableConfigStore.sync` と、出力先を変えたときの組み直し
   - `DevChecks.swift` の削除
   - マイク権限の要求
7. T15: 設定項目の名前を 01 に揃える（`disconnectGraceSeconds`・`finalEngine`・`summarizerKind` の enum・`audioRetentionDays` 0）。`EngineCatalog` は 04 の API を使う（A-25〜A-27）。
8. T4: 重複防止キーを `meeting:generation` にする（A-36）。
9. T16: フィクスチャのパスを直し（A-38）、E2E を `06.1 …` の形に改番する。

### overview への修正
1. §4 と §8b: `RecordingSession.events()` は「呼ぶたびに新しい購読、全員へ流す」と書く。`RecordingEvent` の case 一覧（02 の定義）を §3 に載せる。
2. §3: `UserNotice`/`UserNoticeAction` の case 一覧を載せる（機材、無音、ディスク、議事録の成否、未ログイン、Automations の失敗、上書きの確認、出力先なし）。`UserNotifier` のメソッド名（`withdraw` か `dismiss`）も決める。
3. §3: 型ごと書く Settings の項目は次のとおり（括弧内は表記を揃える旧名や別の型）。
   - `outputFolder: String?`
   - `summarizerKind: SummarizerKind`
   - `shortcuts`: 文字列で保存し、既定は ⌃⌥B/⌃⌥R/⌃⌥P
   - `audioRetentionDays: Int`（0 で削除しない）
   - `disconnectGraceSeconds` とその範囲
   - `finalEngine`/`finalModel`
4. §3: 取り込み音声のファイル名を 1 つに決める（`Track.mic` に加えて）。`DeviceRef.transport` の値の一覧（小文字）と、aggregate UID の接頭辞も決める。
5. §3: `Job` に `generation` などの追加項目を載せる。05 の `JobStore` は 01 の `Job` を保存するだけとする。
6. §8b: `FinalTranscriptionRunner` の正式な署名を載せる。録音中は確定版を `BatchGate` の pause で止めるのか取り消すのかを決める。`isMarker` は「04 の `LiveFeed.isMarker(_:)`。01 の `Utterance` は変えない」と書く。
7. §1 か §8: 計画をまたぐ配線の担当を決める。録音停止・取り込み・復旧の後の `enqueue`、`RecordingSession` → `LiveFeed` → `live.json`、起動時の portable sync。提案は、どれも 06 T13 に置き、組み立て関数は 02 が用意する。
8. §2: 02 T1 の `DevChecks.swift` を例外として認め、06 が消すと書く。
9. §5: `models/` に対応する `AppPaths.modelsDirectory` と、05 の `claude-cwd/`・`batch/` を足す。
10. §7: E2E の番号の付け方を例つきで固定する（`NN.k 名前`。`16`・`M1`・`6b` などは使わない）。最後のタスクを E2E にするという規則と 👤 の置き場所も書く。Swift の版（6.2 か 6.3）と、「CLI から使う型は `public`」を §9 に足す。
