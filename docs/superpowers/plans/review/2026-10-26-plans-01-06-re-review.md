# 計画 01〜06 再レビュー（2026-10-26、コミット 05b2fd7）

前回: `review/2026-10-26-plans-01-06-consistency-review.md`。範囲は前回の A-1〜A-47、B の抜け 9 件、C/D/E 各件、計画 05 ⇔ 06 の突き合わせ、修正で生まれた不整合、書式。行番号は 05b2fd7 時点。

要約: ADDRESSED 76 件、NOT ADDRESSED 2 件（A-35、B-4）。新しい不整合 13 件（N-1〜N-13）。残件がある計画は 02・04・06 と overview。01・03・05 は残件なし。

## 1. 判定表

### A（Consumes ⇔ Produces）

| # | 判定 | 証拠 |
|---|---|---|
| A-1 | ADDRESSED | 05 L35（型を再定義しない）、L97（`JobStore` は 01 の `Job` を保存、`Job.id` = 会議 id） |
| A-2 | ADDRESSED | 05 L43（01 の `meetingDirectory(_:)`・`transcriptsDirectory(_:)`・`queueJobsDirectory`）。拡張は `claudeWorkingDirectory` だけ（L100） |
| A-3 | ADDRESSED | 05 L43（`ManifestStore.all()`） |
| A-4 | ADDRESSED | 05 L43（`SettingsStore.load()`）、L422 |
| A-5 | ADDRESSED | 05 L43（`read(.prompt)`） |
| A-6 | ADDRESSED | 05 L44、06 L817（`outputFolder: String?`） |
| A-7 | ADDRESSED | 01 L139-152、05 L44・L710、06 L813・L833（`Int`、0 で削除しない） |
| A-8 | ADDRESSED | 05 L44（`fillerRemoval`） |
| A-9 | ADDRESSED | 05 T9 が 04 の runner を呼ぶので merge 呼び出しが消えた（L541） |
| A-10 | ADDRESSED | 05 L46、T11 |
| A-11 | ADDRESSED | 05 L46、T11（01 の `titled`/`untitled`/`unique`） |
| A-12 | ADDRESSED | 05 T11（01 の `VaultWriter.write(_:policy:renameToMatchTitle:)`、`.conflict` → `awaitingConfirmation`） |
| A-13 | ADDRESSED | 05 T12 L661（`UpdateIndexStage` は `rebuildIndex()`） |
| A-14 | ADDRESSED | 05 T9 L541（`FinalTranscriptionRunner` を呼ぶだけ） |
| A-15 | ADDRESSED | 04 T11 L687-690、overview L172 |
| A-16 | ADDRESSED | 04 L326、05 L494、overview L173。ただし 06 が gate を渡していない（N-6） |
| A-17 | ADDRESSED | 02 L571・L591（`func events()`、購読ごとに配る） |
| A-18 | ADDRESSED | 06 L275・L620・L679-681（02 の case 名） |
| A-19 | ADDRESSED | 05 L484・L491（`RecordingSessionActivity`）。06 側の呼び出しは N-6 |
| A-20 | ADDRESSED | 02 L714、04 L44-45（`.mic`・`tracks/import-000.wav`） |
| A-21 | ADDRESSED | 01 L135、06 L820（`summarizerKind: SummarizerKind`） |
| A-22 | ADDRESSED | 01 L139-152（r/p の既定） |
| A-23 | ADDRESSED | 06 L64・L578・L834（文字列のまま `KeyCombo(parsing:)`） |
| A-24 | ADDRESSED | 06 L64・L895（`consentNoticeShown` を再定義しない） |
| A-25 | ADDRESSED | 01 L148、03 L305、06 L813・L825（5〜300、03 の丸めを使う） |
| A-26 | ADDRESSED | 06 L826（`finalEngine`/`finalModel`） |
| A-27 | ADDRESSED | 06 L826、04 L260・L264（`entries(role:language:)`・`fromSettings`） |
| A-28 | ADDRESSED | 03 L389-411、06 L56 |
| A-29 | ADDRESSED | 03 L397・L452-453・L494-499、06 L55・L395 |
| A-30 | ADDRESSED | 06 L50・L432（`MeetingsAdapter.saveMinutes` で組み立て、01 は不変） |
| A-31 | ADDRESSED | 06 L47・L895 |
| A-32 | ADDRESSED | 06 L54・L750（`findInterrupted(excluding:)`） |
| A-33 | ADDRESSED | 06 L54（`importFile(_:startedAt:language:progress:) -> Manifest`） |
| A-34 | ADDRESSED | 06 L732（`feed.start(language:hints:)`） |
| A-35 | **NOT ADDRESSED** | 06 L60・L397: `QueuePort` に `retry` が無く、05 の `retry(_:)`/`rerun(_:from:)`（05 L422）を使っていない。06 L786 は `failed` の「再実行」を `.regenerate` に、L621 は `.retry(id)` を `queue.regenerate` に送る。文字起こしで失敗した会議には `final.json` が無いので、05 L686 の `transcriptMissing` で失敗する（R-1） |
| A-36 | ADDRESSED | 01 L210、06 L250・L264（`meeting:generation`） |
| A-37 | ADDRESSED | 06 L742（`DeviceRegistry(storage:mac:)`。03 L250） |
| A-38 | ADDRESSED | 06 L866・L870（`Tests/Fixtures/meetings/20261024-1400-a1b2/`。01 L697） |
| A-39 | ADDRESSED | 04 L44（`AUTONOTE_CLI`） |
| A-40 | ADDRESSED | 02 L80・L414・L422、03 L109 |
| A-41 | ADDRESSED | 02 L484、03 L79 |
| A-42 | ADDRESSED | 02 L52・L57（01 のファイルを Modify） |
| A-43 | ADDRESSED | 05 T9（`Transcript.fallbackEngineLabel`） |
| A-44 | ADDRESSED | 06 L574（`LiveFeed` の出力を表示するだけ） |
| A-45 | ADDRESSED | overview L174。L182 の古い書き方が残っている（N-13） |
| A-46 | ADDRESSED | 01 L133（`modelsDirectory`）、04 L200 |
| A-47 | ADDRESSED | 02 L570（`live(paths:settings:clock:)`）、03 L61・L610、06 L737 |

### B（担当の抜け 9 件）

| # | 判定 | 証拠 |
|---|---|---|
| B-1 マイク許可の要求 | ADDRESSED | 02 L482、06 L752 |
| B-2 復旧後の enqueue | ADDRESSED | 06 L721・L730・L750 |
| B-3 リアルタイムの配線 | ADDRESSED | 06 L709・L723-725・L732・L739 |
| B-4 §7.3 用語のサジェスト（任意） | **NOT ADDRESSED** | overview にも 01〜06 にも §7.3 の記述が無い（grep で 0 件）（R-2） |
| B-5 未ログインの通知 | ADDRESSED | 03 L400（case）、overview L176。ただし出す経路が裁定に反する（N-2） |
| B-6 議事録の書き戻し | ADDRESSED | 06 L432 |
| B-7 起動時の sync と出力先の変更 | ADDRESSED | 06 L731・L736・L743 |
| B-8 停止後・取り込み後の enqueue | ADDRESSED | 06 L716-720・L730 |
| B-9 §15.1 の修正と DevChecks の削除 | ADDRESSED | 06 Task 1 L81-102、L701・L762・L766 |

重複 10 件も A-1〜A-16・A-23・A-42〜A-44 の解消に伴ってすべて 1 か所になった。E2E の番号は NN.k に統一され、vault-state は 01 に一本化された（05 T11）。

### C / D / E

| # | 判定 | 証拠 |
|---|---|---|
| 01 C-1 E2E 名 | ADDRESSED | 01 T14 L763-810（01.1・01.2） |
| 01 C-7 Swift 版 | ADDRESSED | 01 L9 |
| 02 C-1 E2E 名 | ADDRESSED | 02 T16 L793-808（02.1・02.2） |
| 02 C-2 App の例外 | ADDRESSED | overview §8b（DevChecks の例外）、02 L65 |
| 03 C-1 E2E 名 | ADDRESSED | 03 T11 L658-688（03.1・03.2） |
| 03 D-3 T2 の値 | ADDRESSED | 03 L153-161（transport の表） |
| 03 E-3 組み立て関数 | ADDRESSED | 03 L61・L610 |
| 04 C-1 E2E 名 | ADDRESSED | 04 T8 L562-566（04.1〜04.4） |
| 04 C-8 public | ADDRESSED | 04 L48 |
| 04 D-1 最後のタスク | ADDRESSED | 04 T12 L724（👤「（後回し可）」）、T13 L770（E2E、最後のタスク） |
| 05 C-1 E2E 名 | ADDRESSED | 05 L769-770（05.1・05.2） |
| 05 C-4 DevCommands | ADDRESSED | 05 L747・L767 |
| 05 C-5 保存場所 | ADDRESSED | 05 L100・L539、overview L177（`batch/` は使わない） |
| 05 C-8 public | ADDRESSED | 05 L422 ほか（`public` が 41 か所） |
| 05 E-1 想定の名前 | ADDRESSED | 05 L43-48 |
| 06 C-1 E2E 名 | ADDRESSED | 06 L129（06.1）、L867（06.2〜06.6） |
| 06 C-3 音なし | ADDRESSED | 06 L66・L687（`[.alert]` だけ） |
| 06 C-6 最初のタスク | ADDRESSED | 06 Task 1 L81-102 |
| 06 D-2 AppEnvironment.make | ADDRESSED | 06 L734-745（順番と init を明記）。漏れは N-6 |
| 06 E-2 FakeUserNotifier | ADDRESSED | 03 T6（`posted`・`withdrawn`）、06 L56 |
| 06 E-4 01 の Settings を書き換え | ADDRESSED | 06 L64・L578 |

書式（確認 4）:
- 最後のタスクが E2E になっている: 01 T14、02 T16、03 T11、04 T13、05 T14、06 T16。
- E2E 名は NN.k に揃っている。
- 単独の 👤 タスクには「（後回し可）」が付いている（02 T15、03 T10、04 T12）。
- 05 T14 Step 6 と 06 T13〜15 の 👤 は、タスクの中で手で確認する項目なので対象外とした。

## 2. 残った不整合と新しい不整合

| # | 計画 / 行 | 内容 | 直す側と直し方 |
|---|---|---|---|
| R-1（A-35） | 06 L60・L397・L431・L621・L786 | `QueuePort` に `retry` が無い。`failed` の会議の「再実行」が `regenerate` に行き、文字起こしの失敗では `transcriptMissing` で必ず失敗する | **06**: `QueuePort` に `func retry(_ id: MeetingID) async throws` を足す。`QueueAdapter.retry` は、ジョブが `.failed` なら 05 の `retry(_:)`、それ以外（transcript_only・未ログイン）なら `regenerate(_:)` を呼ぶ。L786 の `failed` の「再実行」と L621 の `.retry(id)` はこの `retry` に送る。テスト名を `retryFailedUsesQueueRetry` にする |
| R-2（B-4） | overview §8b | 要件書 §7.3（任意）の担当が書かれていない | **overview**: 「§7.3 は二期目。01〜06 は扱わない」と 1 行足す |
| N-1 | 02 L805 | E2E 02.1 が JSON の `status` に `tooShort` を期待している。01 L80 の raw value は `too_short` なので、必ず FAIL する | **02**: 期待値を `too_short` に直す（括弧内の `rawValue` の説明は残す） |
| N-2 | 06 L67・L254・L269-272・L280・L741 | `AutomationsStage` が `completionNotice` を作って `notifier.post` する。overview L176 は「完了通知は `NoticeRelay` だけが出し、`AutomationsStage` は出さない」と決めている | **06**: `AutomationsStage.init` から `notifier:` を除き、`completionNotice` と L269-272 のテストを Task 12 の `NoticeRelay` に移す。L67 の文も「完了通知は `NoticeRelay`」に直す。L741 の呼び出しは `AutomationsStage(dispatcher:, vault:)` にする |
| N-3 | 06 L648・L683・L749 | `NoticeRelay.notices(previous:current:)` に `rows:` が無い。05 L421 では成功したジョブがスナップショットから消えるので、待ち行列の差分だけでは `minutesGenerated` を出せない。テストも `overwriteConfirmation` だけ | **06**: `notices(previous: QueueStatus, current: QueueStatus, rows: [MeetingRow])` にする（overview L176）。規則は次のとおり。(a) 前回あって今回消えたジョブで、行が `minutes_generated` なら `.minutesGenerated`。(b) `summaryFailure` を新しく持ったジョブは、`not_logged_in` なら `.claudeNotLoggedIn`、それ以外は `.transcriptOnly`。(c) `awaitingConfirmation` が false から true になったら `.overwriteConfirmation`。L683 のテストに (a)・(b) を足し、L749 で `model.meetings` を渡す |
| N-4 | 06 L303・L431 | `QueueAdapter` が `JobProgress` の `summaryFailure`・`awaitingConfirmation`・`generation` を落とす。L303 は `awaitingConfirmation` を状態として扱うが、`JobState` は `pending, running, waiting, failed, done`（01 L209）で、05 L421 では Bool のフィールドになっている | **06**: `QueueItemDTO` に `awaitingConfirmation: Bool`、`summaryFailure: String?`（`SummaryFailureKind.rawValue`）、`generation: Int` を足し、L431 で写す。L303 の注記を「判定は `state == "running"` と `awaitingConfirmation`」に直す |
| N-5 | 06 L60・L250・L271 | `SummaryFailure.Kind.notLoggedIn` は存在しない。05 L97-100 の型は `SummaryFailureKind`（raw `not_logged_in`） | **06**: `SummaryFailureKind.notLoggedIn` に直す（N-2 で移したテストも同様） |
| N-6 | 06 L741 | `PostProcessingQueue(paths:, stages:, activity: 計画 05 の RecordingActivity アダプタ(…))` に `gate:` が無い。05 L494 は `gate?.pause()` なので、渡さないと録音中も確定版の文字起こしが止まらない（§13・overview L173 に反する）。アダプタ名も書かれていない | **06**: `PostProcessingQueue(paths: paths, stages: stages, activity: RecordingSessionActivity(session: session), gate: gate)` にする。`gate` は同じ `makeQueue` で runner に渡したものと同じインスタンス。`AppWiringTests` か新しいテストで、録音中に `gate.isPaused == true` を確かめる |
| N-7 | 04 L326 | 「`isPaused` は計画 05 は使わない」とあるが、05 L501・L508 のテストは `gate.isPaused` を読む。overview L173 の `BatchGate` 宣言にも `isPaused` が無い | **04**: 「計画 05 は使わない」を「計画 05 のテストが読む」に直す。overview への記載は Lead の判断点 2 |
| N-8 | 06 L739（04 L637） | `LiveFeed.make` は `settings.defaultLanguage` でエンジンを解決する。一方 06 は `start(language:)` に会議の言語（`coordinator.current().language`）を渡すので、手動で言語を変えた会議では対応しないエンジンを選びうる | **06**: `makeFeed` で `var s = settings.load(); s.defaultLanguage = coordinator.current().language` としてから `LiveFeed.make(settings: s, …)` を呼ぶ（04 の署名は変えない） |
| N-9 | 04 L637 | `EngineChoice.fromSettings(…, machine:)` の `machine` に何を渡すかが書かれていない（`make` に machine の引数が無い） | **04**: T4 の `EngineCatalog` に `let machine: MachineKind` を公開し、`make` は `catalog.machine` を渡すと書く |
| N-10 | overview L95（05 L432・L434） | overview は「再生成のたびに +1」とだけ書く。05 は上限後の自動再試行（`rerun(from: "summarize")`）でも +1 する。05 のほうが正しく、+1 しないと transcript_only の回と鍵が重なって `minutes_generated` の Automation が走らない | **overview**: 「`summarize` 以前からやり直すたびに +1（再生成、レート上限後の自動再試行）」に直す |
| N-11 | 06 L43・L707・L897 | 「05 は改訂中」「05 の `enqueue` が throws なら握る」が残っている。05 L422 で `enqueue` は throws しないと確定した | **06**: L707 の括弧書きを消す。L43・L897 の「改訂中」の前提を「05 の確定版（05b2fd7）に合わせた」に直す |
| N-12 | 02 L9 | Tech Stack が「Swift 6.2（strict concurrency）」のまま。01 L9 と overview §9 は「6.3 ツールチェーン / tools-version 6.2」 | **02**: 01 L9 と同じ書き方にする |
| N-13 | overview L182 | 「`Utterance`（話者 `.unknown`、`isMarker`）」がフィールドのように読める（L174 では関数と決めている） | **overview**: 「（話者 `.unknown`。判定は 04 の `LiveFeed.isMarker(_:)`）」にする |

確認 3 で問題が無かったもの:
- 02 `live(clock:)` の既定値: 03 L610・06 L737 とも既定値で呼んでいる。
- 01 `AppPaths.resolve(environment:)`: 06 L735・L866 と合っている。
- 03 `RecorderSnapshot` と `RecorderState`: 03 L303・L397 と 06 L55・L303・L573・L580 が一致する。
- 05 ⇔ 06 の `Job` の形: 01 L210 と 06 L60・L250 が一致する。
- `PostProcessingQueue` の init: `gate:` 以外は一致する。
- `enqueue` は throws しない: 06 L707 の文言が残っているだけ（N-11）。
- `audioRetentionDays`: どの計画も `Int` で、0 は削除しない（06 L833）。

## 3. 計画ごとの修正指示（残件のある計画だけ）

### 計画 02
1. L805（02.1）: 期待する `status` を `too_short` にする（N-1）。
2. L9: Tech Stack を 01 L9 と同じ「6.3 ツールチェーン / tools-version 6.2」にする（N-12）。

### 計画 04
1. L326: 「計画 05 は使わない」を「計画 05 のテスト（`QueueRecordingPauseTests`）が読む」に直す（N-7）。
2. T4 の `EngineCatalog` に `public let machine: MachineKind` を足し、L637 の `machine:` に `catalog.machine` を渡すと書く（N-9）。

### 計画 06
1. Task 3 か Task 4（L250-L280）と L67:
   - `AutomationsStage` から `notifier:` と `completionNotice` を外す。
   - L269-272 のテストは Task 12 へ移す。
   - L741 の呼び出しも直す（N-2）。
2. Task 12（L648・L683）:
   - `NoticeRelay.notices(previous:current:rows:)` にする。
   - (a) 消えたジョブで行が minutes_generated、(b) summaryFailure、(c) awaitingConfirmation の 3 つの規則とテストを足す。
   - L749 で `model.meetings` を渡す（N-3）。
   - 型名は `SummaryFailureKind` にする（N-5、L60・L250・L271 も直す）。
3. Task 8（L303・L397・L431）:
   - `QueueItemDTO` に `awaitingConfirmation`・`summaryFailure`・`generation` を足す。
   - `QueuePort.retry` を足す。`.failed` なら 05 の `retry`、それ以外は `regenerate` を呼ぶ。
   - L621 の `.retry(id)` と L786 の `failed` の「再実行」を `retry` に送る（N-4、R-1）。
4. Task 13 L741: 次の形にする（N-6）。
   ```swift
   PostProcessingQueue(paths:, stages:, activity: RecordingSessionActivity(session: session), gate: gate)
   ```
   - runner と同じ `gate` を渡す。
   - 録音中に `gate.isPaused` になるテストを `AppWiringTests` に足す。
5. Task 13 L739: `makeFeed` は、会議の言語を `defaultLanguage` に入れた設定を `LiveFeed.make` に渡す（N-8）。
6. 「改訂中」の名残を消す: L707 の「throws なら」の括弧書き、L43・L897 の前提（N-11）。

### overview（Lead）
1. §8b に「§7.3（用語のサジェスト）は二期目」と足す（R-2）。
2. L95 の `generation` の説明を「summarize 以前からやり直すたびに +1（再生成・上限後の自動再試行）」にする（N-10）。
3. L182 の `isMarker` の書き方を直す（N-13）。
4. Lead の判断点（下の 4 件。直す側は overview）:
   - L175 の組み立て関数を `PostProcessingQueue(paths:stages:activity:gate:)` にし、「runner と同じ `BatchGate` を渡す」と書く。今の形のままだと N-6 が再発する。
   - L173 の `BatchGate` に `nonisolated var isPaused: Bool` を足すか決める。04 と 05 は既に使っているので、足すのが妥当。
   - L176 の「`QueueSnapshot` の差分から」に、「成功したジョブはスナップショットから消えるので、`minutesGenerated` は `rows:` の状態で判定する」と補う。
   - `.retry` 通知アクションの行き先（`failed` なら `retry`、それ以外なら `regenerate`）を §3 の `UserNoticeAction` に一言書くか決める。
