# AutoNote 計画 02: 音声取得 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** システム音（process tap）とマイク（AVAudioEngine）を 16kHz/16bit/mono の 5 分分割 WAV に会議タイムラインどおり録り、一時停止・ブックマーク・無音検知・ディスク空き監視・短すぎる録音・クラッシュ復旧・音声ファイル取り込みまでを `RecordingSession` ほかの API として計画 03・04・06 に渡す。

**Architecture:** 音声コールバック（tap の IOProc、AVAudioEngine の tap）は固定長リングバッファへのコピーだけを行い、取り出しタスクが 16k/mono/Int16 に変換して `AudioChunk`（ホスト時刻から求めた会議タイムライン上の開始時刻つき）を出す。`RecordingSession`（actor）が 2 本の `AudioSource` を束ね、`TimelineAligner` で欠けた時間を無音で埋めながら `WAVSegmentWriter` に書き、manifest を更新する。Core Audio・AVAudioEngine・ディスク空き・時計はすべて protocol の後ろに置き、フェイクとファイル入力で自動テストする。実機でしか分からない部分（許可、tap の受信、BT 出力、ボイスプロセッシング）は 👤 手順にする。

**Tech Stack:** Swift 6.2（strict concurrency）/ Core Audio process tap（`CATapDescription`、`AudioHardwareCreateProcessTap`、aggregate device、IOProc）/ AVFoundation（`AVAudioEngine`、`AVAudioConverter`、`AVAssetReader`）/ `Synchronization`（`Atomic`）/ Speech（Task 1 の確認だけ）/ Swift Testing

**Spec:** `docs/superpowers/specs/2026-10-24-autonote-design.md`（§3.4、§5.1〜5.9、§10、§11.5 の猶予中の無音、§17）と `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md`（共通契約）。根拠: `docs/superpowers/research/2026-10-24-spike-results.md` 項目 3・5・9・10、`Spikes/Sources/TapCapture/main.swift`、`docs/superpowers/plans/2026-10-24-autonote-00-progress.md` の「計画 02 への申し送り」

**ブランチ:** `plan-02`（起点 `plan-01`）。push しない。

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

（「本書」は overview を指す。）
本計画だけの決まり:
- 音声コールバックの中ではロック・メモリ確保・ディスク I/O・ログ出力・`await` をしない（overview §6）。`AudioRingBuffer.write` だけを呼ぶ
- Core Audio の破棄（`AudioDeviceStop` 〜 `AudioHardwareDestroyProcessTap`）はメインスレッドで同期的に呼ばない。専用の `DispatchQueue` で行い、呼び手はタイムアウト付きで待つ（要件書 §3.4）
- テストは `Tests/AutoNoteCoreTests/Audio/`、フェイクは `Sources/AutoNoteTestSupport/` に置く。実行は `swift test --filter <スイート名>`
- 各タスクの Produces に書いた `AutoNoteCore` の型・関数・init はすべて `public`（`autonote dev …` と計画 06 の App から使う）。テスト専用の口（`waitUntilIdle`、`tick`）だけ `internal`

## Review Focus

1. 会議中に音を出すプロセスが長く無い（相手が黙る・ミュート）と IOProc が呼ばれない → システム音 WAV はそれでもマイクと同じ長さになり、後の発話が正しい時刻に来る（Task 2 `alignerPadsGap`、Task 8 `chunkStartFollowsHostTimeAcrossGap`、Task 10 `systemTrackIsPaddedToMicLength`）
2. 初回の許可ダイアログに応答しないまま停止 → `AudioDeviceDestroyIOProcID` が数分止まっても `stop()` はタイムアウトで戻り、アプリも CLI も固まらない（Task 8 `stopReturnsWithinTimeoutWhenTeardownBlocks`）
3. Bluetooth ヘッドセットのマイクは 16k/24k/8k などの低いレートで来る → どの入力レートでも 16k に変換され、長さが実時間と合う（Task 4 `convertsBluetoothRates`）
4. 録音中のクラッシュで最後の分割 WAV のヘッダが未確定（サイズ 0）→ 復旧後に読めて、長さが manifest に入る（Task 12 `recoverRepairsUnfinalizedHeader`）
5. 片方の音源だけ開始に失敗（tap 作成エラー、マイク機材が消えた）→ もう片方で録音を続け、無音警告の印と理由のイベントが出る。マイク許可が無い場合だけは録音を始めない（Task 10 `systemFailureContinuesWithMic`、`micPermissionDeniedRefusesToStart`）

---

## 計画 01 に前提とする型と API（Lead が計画 01 と揃える）

overview §3 の型（`MeetingID`、`TimelineTime`、`Track`、`Language`、`Bookmark`、`PauseInterval`、`TrackFile`、`MeetingStatus`、`MeetingSource`、`DeviceRef`、`Manifest`）は名前と形をそのまま使う。加えて次を前提にする:

| 前提 | 想定する形 |
|---|---|
| `AudioSource`（計画 01 の `Sources/AutoNoteCore/Audio/Protocols.swift`。本計画は作らず、そのまま使う） | overview §4 のとおり。`var track: Track { get }`、`start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws`、`stop() async` |
| `AudioChunk`（計画 01 の Task 4） | `public struct AudioChunk: Sendable, Equatable { static let sampleRate = 16_000.0; var track: Track; var samples: [Int16]; var start: TimelineTime; var hostTime: UInt64; var duration: Double { get } }`（計画 01 の案と同じ）。`samples` は 16kHz/mono/Int16、`start` は会議タイムライン、`hostTime` は先頭サンプルの mach ホスト時刻。音源は自分の `track` を入れる |
| 型の公開 | 上記の型はすべて `public` で memberwise の `public init` を持つ。`TimelineTime(seconds:)`、`MeetingID.make(start:)` |
| `AppPaths` | 計画 01 の案のとおり `init(root:)`、`static var standard`、`recordingsDirectory`、`logsDirectory`、`meetingDirectory(_:)`（`recordings/<id>`）、`manifestFile(_:)`、`tracksDirectory(_:)`（`recordings/<id>/tracks` を想定） |
| `ManifestStore` | 計画 01 の案のとおり `save(_:) throws`、`load(_:) throws -> Manifest`、`update(_:_:) throws -> Manifest`、`all() -> [Manifest]`、`unfinishedRecordings() -> [Manifest]`（status `recording`）、`delete(_:) throws`（`recordings/<id>` ほかを消す） |
| `FakeAudioSource`、`TemporaryDirectory.make() -> URL`（TestSupport） | 計画 01 が `Sources/AutoNoteTestSupport/Fakes.swift` に置く（`FakeAudioSource(track:chunks:)`）。本計画 Task 2 はそのファイルを Modify して `emit` と `startError` を足す |
| CLI の `dev` 振り分け | 計画 01 の `enum DevCommands { static func run(_ args: [String]) async -> Int32 }`（`Sources/autonote/DevCommands.swift`）。本計画は `record` と `import` をここに足す |
| `Settings` | 計画 01 の `voiceProcessing: Bool`（既定 false）だけを `RecordingSession.live(paths:settings:clock:)`（Task 10）が読む |

### Task 1: TCC まとめ確認（👤 利用者）と一時的な開発メニュー

overview §8 の 3 項目（システム音声録音の許可の持続、許可なしの挙動、DictationTranscriber が許可不要なこと）と、IOProc が無音時に呼ばれない件の BT 出力での再確認、aggregate に出力デバイスを含めない構成で受信できるかを確かめる。

**方式の決定: `.app` に最小の「開発」サブメニューを足す（CLI 側の確認にはしない）。** 理由: TCC の責任プロセスは起動元で決まり、`autonote dev …` をターミナルから打つとターミナル（Orca.app）の許可を見てしまう（スパイク項目 9 の誤測定と同じ）。確かめたいのは `open` で起動した `com.yutaokoshi.autonote` の許可なので、`.app` の中から呼ぶ必要がある。計画 00 の骨組みにはすでに「マイク許可を確認」項目があり、その隣に足すだけで済む。「計画 06 まで App は骨組みのまま」の例外（overview §8b で承認済み）として `DevChecks.swift` 1 ファイルとメニュー 2 項目に限り、計画 06 の Task 13 で削除する。

**Files:**
- Create: `Sources/AutoNoteApp/DevChecks.swift`
- Modify: `Sources/AutoNoteApp/AutoNoteApp.swift`（`Menu("開発")` に既存の「マイク許可を確認」を移し、2 項目を足す）
- Modify（👤 の結果を反映）: `docs/superpowers/research/2026-10-24-spike-results.md`（項目 2・3・9）、`docs/superpowers/specs/2026-10-24-autonote-design.md`（§3.4、§6.3、§19 の項目 3・9）
- Create: `docs/superpowers/research/2026-10-24-spike-raw/plan02-task1-tcc.log`

**Interfaces:**
- Consumes: `AppPaths.standard.logsDirectory`
- Produces: なし（一時コード。後続タスクは使わない）。結果として、ProcessTapSource の aggregate 構成（`AggregateLayout.tapOnly` か `.withOutputClock`）の既定を決める

- [ ] **Step 1: `DevChecks.swift` を実装する**

`enum DevChecks`（`nonisolated`。IOProc ブロックを MainActor 文脈で作ると SIGILL になる。スパイク項目 3）に 2 つの処理を置き、結果を `<logsDirectory>/dev-checks.log` に 1 行ずつ追記する（`open` 起動では標準出力が見えないため）:
- `static func checkSystemAudio(seconds: Int = 15) async`: TapCapture の手順 1〜8 を写す。ただし (a) aggregate は UID を `com.yutaokoshi.autonote.tap.<UUID>` にし（計画 03 が機材と誤認しないため）、**出力デバイスを含めない** `tapOnly` 構成（`MainSubDeviceKey` と `SubDeviceListKey` なし、`TapList` は drift compensation あり、`TapAutoStart`=true、`IsPrivate`=true）で作る、(b) IOProc では `Atomic<Int>` のカウンタ（callbacks、frames）と固定長配列への最大値更新（peak）だけを行い、ロック・確保・ファイル書き込みをしない、(c) 1 秒ごとのコールバック数、各コールバック間で `mHostTime` が 0.1 秒以上飛んだ箇所の「ホスト時刻の飛び（秒）と `mSampleTime` の飛び（フレーム）」を最大 16 件記録する、(d) `tapOnly` で callbacks=0 なら同じ秒数を `withOutputClock`（スパイクと同じ、出力デバイスを MainSubDevice に入れる）で取り直す、(e) 破棄は専用キューで行い 10 秒で打ち切ってログに `teardown timeout` を残す。ログ行の形: `system layout=tapOnly callbacks=N frames=N peak_dbfs=X per_second=[…] gaps=[{host_s:…, sample_frames:…}]`
- `static func checkDictation(file: URL) async`: `SFSpeechRecognizer.authorizationStatus()` をログに出してから、`Spikes/Sources/AppleSpeechProbe` の dictation `--file` 経路（`DictationTranscriber(locale: ja_JP, preset:)` → `SpeechAnalyzer(modules:)` → `analyzeSequence(from:)`）を写して認識し、本文の先頭 100 文字とエラーをログに出す。許可の要求（`requestAuthorization`）は呼ばない

メニュー項目: 「システム音声を確認（15 秒）」「Dictation を確認（/tmp/autonote-dictation.aiff）」。
- [ ] **Step 2: ビルドと E2E** — Run: `scripts/build-app.sh && scripts/e2e-check.sh --quick` → Expected: build 成功、E2E は FAIL 0（項目 7b の menu bar 項目は `waveform` のまま）
- [ ] **Step 3: Commit** — `git add Sources/AutoNoteApp/ && git commit -m "chore: add temporary dev menu for TCC checks"`
- [ ] **Step 4: 👤 利用者 — システム音声録音の許可の持続**

1. `tccutil reset AudioCapture com.yutaokoshi.autonote`（効かなければ システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオ録音 で AutoNote を外す）
2. 別ターミナルで `while true; do afplay /System/Library/Sounds/Submarine.aiff; done` を流す
3. `open build/AutoNote.app` → 開発 >「システム音声を確認」→ ダイアログで許可 → もう一度「システム音声を確認」
4. `sqlite3 -readonly ~/Library/Application\ Support/com.apple.TCC/TCC.db "select service,client,auth_value,auth_reason,datetime(last_modified,'unixepoch','localtime') from access where client like 'com.yutaokoshi.autonote%'"` の出力を記録
5. AutoNote を終了 → `Resources/Info.plist` の `CFBundleVersion` を 1 上げて `scripts/build-app.sh` → `open build/AutoNote.app` →「システム音声を確認」

Expected（記録すること）: 5 でダイアログが出ない、`kTCCServiceAudioCapture` の行の `last_modified` が 4 と同じ、ログの callbacks > 0。`tapOnly` で callbacks > 0 か（0 なら `withOutputClock` の行の値）
- [ ] **Step 5: 👤 利用者 — 許可なしの挙動（再起動後）**

1. システム設定で AutoNote の「システムオーディオ録音のみ」をオフ → TCC.db の行が `auth_value=0` になったことを確かめる
2. Mac を再起動 → Submarine のループを流す → `open build/AutoNote.app` →「システム音声を確認」
3. `log show --last 3m --predicate 'process == "coreaudiod" OR process == "tccd"' | grep -iE 'tap|AudioCapture'` を保存
4. 許可をオンに戻す

Expected（記録すること）: callbacks、frames、peak_dbfs、ダイアログの有無、coreaudiod のエラー行。届いた／無音のサンプルが届いた（peak が -inf）／コールバックが来ない、のどれか
- [ ] **Step 6: 👤 利用者 — DictationTranscriber が音声認識の許可なしで動くか**

1. `tccutil reset SpeechRecognition com.yutaokoshi.autonote`
2. `say -v Kyoko -o /tmp/autonote-dictation.aiff "本日の定例会議を始めます。議題は三つあります。"`
3. `open build/AutoNote.app` →「Dictation を確認」→ TCC.db の `kTCCServiceSpeechRecognition` の行を見る

Expected（記録すること）: ダイアログの有無、`authorizationStatus` の値、認識された本文、TCC.db の行の有無
- [ ] **Step 7: 👤 利用者 — BT 出力で無音時に IOProc が止まるか**

1. Shokz（OpenRun Pro 2）を接続し、出力を Shokz にする
2. `open build/AutoNote.app` →「システム音声を確認」を押してすぐ、別ターミナルで `sleep 5; afplay /System/Library/Sounds/Glass.aiff; sleep 5; afplay /System/Library/Sounds/Glass.aiff`

Expected（記録すること）: `per_second` が音の鳴った秒だけ 0 でないか、`gaps` の `host_s` と `sample_frames` の関係（`mSampleTime` が無音中も進むか止まるか）。内蔵スピーカーでも同じ操作をして比べる
- [ ] **Step 8: 結果を記録する**

- `dev-checks.log` と Step 4〜7 の TCC.db・log の出力を `docs/superpowers/research/2026-10-24-spike-raw/plan02-task1-tcc.log` に写す（Bluetooth の UID が出たら下 3 オクテットを `xx-xx-xx` に伏せる）
- 結果表: 項目 3 の結論に「自己署名 `.app` 単体・再起動後の許可なしの挙動」「BT 出力での IOProc の止まり方」「`tapOnly` で受信できたか」、項目 9 の結論にシステム音声録音の許可の持続、項目 2 に AutoNote.app 単体での Dictation の許可要否を、測定値つきで足す
- 要件書: §3.4 の「システム音声録音の許可が再ビルド後も保たれるかは未確認。計画 02 の最初のタスクで確かめる」と「拒否時の挙動は計画 02 の最初のタスクで、自己署名 `.app` 単体・再起動後に再確認する」を結果で置き換える。§6.3 の Dictation の括弧書きを結果で置き換える。§19 の項目 3・9 の状態を更新する
- 結果による分岐（実装者は該当すれば Lead に報告してから進む）:
  - `tapOnly` で受信できなかった → Task 8 の `AggregateLayout` の既定を `.withOutputClock` にし、IOProc では tap の形式（チャンネル数）に合う最後のバッファだけを読む
  - 許可なしで「peak が -inf のサンプルが届く」→ Task 7 の「全サンプル 0 のチャンクは受信とみなさない」規則でそのまま検知できる（追加作業なし）
  - Dictation に許可が要った → `Resources/Info.plist` に `NSSpeechRecognitionUsageDescription` を足し、E2E 項目 5 のキー一覧に加える（計画 04 の前提が変わる）
- [ ] **Step 9: Commit** — `git add docs/superpowers/research/ docs/superpowers/specs/2026-10-24-autonote-design.md Resources/Info.plist scripts/e2e-check.sh && git commit -m "docs: record TCC checks for system audio and dictation"`

### Task 2: 会議の時計と時刻合わせ、FakeAudioSource の整え

**Files:**
- Create: `Sources/AutoNoteCore/Audio/MeetingClock.swift`, `Sources/AutoNoteCore/Audio/TimelineAligner.swift`
- Create: `Sources/AutoNoteTestSupport/FakeHostClock.swift`, `Sources/AutoNoteTestSupport/AudioFixtures.swift`
- Modify: `Sources/AutoNoteTestSupport/Fakes.swift`（計画 01 の `FakeAudioSource` に `emit` と `startError` を足す。`AudioSource` の宣言がある計画 01 の `Audio/Protocols.swift` は変えない）
- Test: `Tests/AutoNoteCoreTests/Audio/MeetingClockTests.swift`, `Tests/AutoNoteCoreTests/Audio/TimelineAlignerTests.swift`

**Interfaces:**
- Consumes: `AudioChunk`、`AudioSource`、`TimelineTime`、`Track`
- Produces:
  - `public protocol HostClock: Sendable { func hostTime() -> UInt64; func seconds(fromHostTicks ticks: UInt64) -> Double; func hostTicks(fromSeconds s: Double) -> UInt64 }`、`public struct MachHostClock: HostClock`（`mach_absolute_time` と `mach_timebase_info`。Intel は 1/1、Apple Silicon は 125/3）
  - `public struct MeetingClock: Sendable { public init(origin: UInt64, host: any HostClock); public let origin: UInt64; public func timeline(hostTime: UInt64) -> TimelineTime; public func now() -> TimelineTime }`。origin より前のホスト時刻は負の秒を返す
  - `public struct TimelineAligner: Sendable { public static let tolerance: Double = 0.05; public init(start: TimelineTime); public private(set) var writtenEnd: TimelineTime; public mutating func place(_ chunk: AudioChunk) -> Placement; public mutating func padding(to end: TimelineTime) -> Int }`、`public struct Placement: Equatable, Sendable { public var silenceBefore: Int; public var samples: ArraySlice<Int16> }`
  - TestSupport: `public final class FakeHostClock: HostClock, @unchecked Sendable { public init(); public func advance(_ seconds: Double); public func hostTime(atSeconds s: Double) -> UInt64 }`（1 tick = 1 ns）。`public actor FakeAudioSource: AudioSource { public init(track: Track, chunks: [AudioChunk] = [], startError: (any Error)? = nil); public func emit(_ chunk: AudioChunk); public private(set) var isStarted: Bool; public private(set) var stopCount: Int }`（`emit` は `start` で受け取った `onBuffer` を同期的に呼ぶ）。`public enum AudioFixtures { public static func tone(start: Double, seconds: Double, value: Int16 = 1000, track: Track = .mic) -> AudioChunk; public static func zeros(start: Double, seconds: Double, track: Track = .mic) -> AudioChunk; public static func sine(frequency: Double, amplitude: Float, seconds: Double, sampleRate: Double, channels: Int) -> [Float] }`（`sine` はインターリーブ）。`extension MeetingClock { public static func fake(_ host: FakeHostClock = FakeHostClock()) -> MeetingClock }`（origin 0）

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct TimelineAlignerTests {
    @Test func contiguousChunkWithinToleranceIsAppended() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        let p = a.place(AudioFixtures.tone(start: 1.03, seconds: 1))
        #expect(p.silenceBefore == 0 && p.samples.count == 16_000)
        #expect(abs(a.writtenEnd.seconds - 2.0) < 1e-9)
    }
    @Test func alignerPadsGap() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        #expect(a.place(AudioFixtures.tone(start: 3, seconds: 1)).silenceBefore == 32_000)
    }
    @Test func overlapIsDroppedFromHead() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        #expect(a.place(AudioFixtures.tone(start: 0.8, seconds: 1)).samples.count == 12_800)
        #expect(a.place(AudioFixtures.tone(start: 0.0, seconds: 0.5)).samples.isEmpty)
    }
    @Test func chunkBeforeStartIsTrimmed() {
        var a = TimelineAligner(start: .init(seconds: 10))
        #expect(a.place(AudioFixtures.tone(start: 9.5, seconds: 1)).samples.count == 8_000)
    }
    @Test func paddingToEnd() {
        var a = TimelineAligner(start: .init(seconds: 0))
        _ = a.place(AudioFixtures.tone(start: 0, seconds: 1))
        #expect(a.padding(to: .init(seconds: 4)) == 48_000)
        #expect(a.padding(to: .init(seconds: 4)) == 0)
    }
}
@Suite struct MeetingClockTests {
    @Test func timelineFromHostTime() {
        let host = FakeHostClock()
        let clock = MeetingClock(origin: host.hostTime(), host: host)
        #expect(clock.timeline(hostTime: host.hostTime(atSeconds: 2.5)).seconds == 2.5)
        host.advance(7); #expect(clock.now().seconds == 7)
    }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter TimelineAlignerTests` と `--filter MeetingClockTests` → Expected: FAIL（`TimelineAligner` / `FakeHostClock` が未定義）
- [ ] **Step 3: Implement** `MeetingClock`、`TimelineAligner`、TestSupport の 3 ファイル

規則（`place`）: `d = chunk.start − writtenEnd`。`|d| ≤ tolerance` なら全サンプルをつなぐ、`d > tolerance` なら `round(d × 16000)` の無音を前に置く、`d < −tolerance` なら先頭の `round(−d × 16000)` サンプルを捨てる。`writtenEnd` は書いたサンプル数（無音を含む）から計算し、チャンクの時刻からは計算しない（小さなずれを累積させず、tolerance を超えた時点で一度に直す）。
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter TimelineAlignerTests` と `--filter MeetingClockTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/MeetingClock.swift Sources/AutoNoteCore/Audio/TimelineAligner.swift Sources/AutoNoteTestSupport/ Tests/AutoNoteCoreTests/Audio/ && git commit -m "feat: add meeting clock and timeline aligner"`

### Task 3: 固定長リングバッファ

**Files:**
- Create: `Sources/AutoNoteCore/Audio/AudioRingBuffer.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/AudioRingBufferTests.swift`

**Interfaces:**
- Consumes: なし
- Produces: `public final class AudioRingBuffer: @unchecked Sendable { public struct Record: Sendable, Equatable { public var hostTime: UInt64; public var sampleTime: Double; public var frameCount: Int }; public init(channels: Int, capacityFrames: Int, recordCapacity: Int = 4096); public let channels: Int; @discardableResult public func write(_ abl: UnsafePointer<AudioBufferList>, frameCount: Int, hostTime: UInt64, sampleTime: Double) -> Bool; public func read(into buffer: inout [Float]) -> Record?; public var droppedFrames: Int { get } }`。書き手 1・読み手 1 専用

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct AudioRingBufferTests {
    @Test func roundTripsInterleavedFrames() throws {
        let ring = AudioRingBuffer(channels: 2, capacityFrames: 1024)
        try withABL(interleaved: [1, 2, 3, 4, 5, 6], channels: 2) { ring.write($0, frameCount: 3, hostTime: 10, sampleTime: 0) }
        var out: [Float] = []
        #expect(ring.read(into: &out) == .init(hostTime: 10, sampleTime: 0, frameCount: 3))
        #expect(out == [1, 2, 3, 4, 5, 6])
        #expect(ring.read(into: &out) == nil)
    }
    @Test func nonInterleavedIsInterleavedOnWrite() throws {
        let ring = AudioRingBuffer(channels: 2, capacityFrames: 1024)
        try withABL(planar: [[1, 3], [2, 4]]) { ring.write($0, frameCount: 2, hostTime: 0, sampleTime: 0) }
        var out: [Float] = []; _ = ring.read(into: &out)
        #expect(out == [1, 2, 3, 4])
    }
    @Test func wrapsAround() { /* capacity 8 frames に 5 フレームを 10 回 write/read し、毎回内容が一致 */ }
    @Test func overflowDropsWholeCallbackAndCounts() throws {
        let ring = AudioRingBuffer(channels: 1, capacityFrames: 4)
        #expect(try writeFrames(ring, 3) == true)
        #expect(try writeFrames(ring, 3) == false)
        #expect(ring.droppedFrames == 3)
    }
    @Test func concurrentProducerConsumerKeepsOrder() async { /* 書き手スレッドが 20,000 回、各 64 フレーム（値 = 通し番号）を write、読み手タスクが並行して read。 読めた Record の hostTime は単調増加、各 Record のサンプルは全部同じ通し番号、落ちた分は droppedFrames と一致 */ }
}
```

`withABL` / `writeFrames` はテストファイル内の補助（`AudioBufferList` を組んでクロージャに渡す）。
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter AudioRingBufferTests` → Expected: FAIL（`AudioRingBuffer` が未定義）
- [ ] **Step 3: Implement `AudioRingBuffer`**

サンプル領域とレコード領域は `init` で `UnsafeMutablePointer` に確保し、以後は確保しない。読み書き位置は `Synchronization.Atomic<Int>`（書き手は release、読み手は acquire）。`write` はサンプルとレコードの両方に空きがあるときだけ書き、無ければ何も書かずに `droppedFrames` を増やして false（途中まで書かない）。インターリーブかどうかは `abl.mNumberBuffers` と `mNumberChannels` で判断する。`write` の中で Swift の配列・クロージャ生成・ログを使わない。
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter AudioRingBufferTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/AudioRingBuffer.swift Tests/AutoNoteCoreTests/Audio/AudioRingBufferTests.swift && git commit -m "feat: add lock-free audio ring buffer"`

### Task 4: 16kHz/mono/Int16 への変換とレベル

**Files:**
- Create: `Sources/AutoNoteCore/Audio/SampleConverter.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/SampleConverterTests.swift`

**Interfaces:**
- Consumes: `AudioFixtures.sine`
- Produces: `public struct SampleConverter { public init(inputSampleRate: Double, inputChannels: Int) throws; public mutating func convert(_ interleaved: [Float]) -> [Int16]; public mutating func flush() -> [Int16]; public mutating func reset() }`（Sendable ではない。取り出しタスクの中だけで使う）、`public enum AudioLevel { public static func peakDBFS<C: Collection>(_ samples: C) -> Double where C.Element == Int16 }`（全部 0 なら `-Double.infinity`）、`public enum SampleConverterError: Error, Equatable { case unsupportedFormat(sampleRate: Double, channels: Int) }`

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct SampleConverterTests {
    @Test func stereo48kTo16kMono() throws {
        var c = try SampleConverter(inputSampleRate: 48_000, inputChannels: 2)
        let src = AudioFixtures.sine(frequency: 1000, amplitude: 0.5, seconds: 1, sampleRate: 48_000, channels: 2)
        var out: [Int16] = []
        for i in stride(from: 0, to: src.count, by: 960) { out += c.convert(Array(src[i..<min(i + 960, src.count)])) }
        out += c.flush()
        #expect(abs(out.count - 16_000) <= 32)
        #expect(abs(AudioLevel.peakDBFS(out) - (-6.02)) < 0.5)
        #expect(abs(zeroCrossings(out) - 2000) <= 20)
    }
    @Test func downmixAveragesChannels() throws { /* L = +x、R = −x の 48k stereo → peak が −60 dBFS 未満 */ }
    @Test func clipsInsteadOfOverflowing() throws { /* 振幅 1.5 の正弦 → max == 32767、min == −32767 か −32768、符号反転なし */ }
    @Test(arguments: [8_000.0, 16_000, 24_000, 44_100])
    func convertsBluetoothRates(rate: Double) throws {
        var c = try SampleConverter(inputSampleRate: rate, inputChannels: 1)
        let out = c.convert(AudioFixtures.sine(frequency: 300, amplitude: 0.5, seconds: 2, sampleRate: rate, channels: 1)) + c.flush()
        #expect(abs(out.count - 32_000) <= 64)
    }
    @Test func silenceIsMinusInfinity() { #expect(AudioLevel.peakDBFS([Int16](repeating: 0, count: 10)) == -.infinity) }
    @Test func rejectsZeroChannels() { #expect(throws: SampleConverterError.self) { try SampleConverter(inputSampleRate: 48_000, inputChannels: 0) } }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter SampleConverterTests` → Expected: FAIL（`SampleConverter` が未定義）
- [ ] **Step 3: Implement**

チャンネル平均で mono にしてから、`AVAudioConverter`（Float32 mono 入力レート → Float32 mono 16k、`sampleRateConverterQuality = .high`）で変換し、`max(-1, min(1, x)) * 32767` を丸めて Int16 にする。入力が 16k mono なら変換器を通さない。`AVAudioConverter` と作業用バッファは `init` で作り、`convert` の中で使い回す（呼ぶのは取り出しタスクなので確保は許されるが、毎回作らない）。
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter SampleConverterTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/SampleConverter.swift Tests/AutoNoteCoreTests/Audio/SampleConverterTests.swift && git commit -m "feat: add 16 kHz mono sample converter"`

### Task 5: WAV ファイルと 5 分分割の書き手

**Files:**
- Create: `Sources/AutoNoteCore/Audio/WAVFile.swift`, `Sources/AutoNoteCore/Audio/WAVSegmentWriter.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/WAVFileTests.swift`, `Tests/AutoNoteCoreTests/Audio/WAVSegmentWriterTests.swift`

**Interfaces:**
- Consumes: `TimelineAligner`、`AudioChunk`、`TrackFile`、`Track`
- Produces:
  - `public struct WAVInfo: Equatable, Sendable { public var sampleRate: Int; public var channels: Int; public var bitsPerSample: Int; public var dataBytes: Int; public var durationSeconds: Double }`
  - `public enum WAVFile { public static let headerSize = 44; public static func header(sampleRate: Int, channels: Int, bitsPerSample: Int, dataBytes: Int) -> Data; public static func info(_ url: URL) throws -> WAVInfo; public static func readSamples(_ url: URL) throws -> [Int16]; public static func repairHeader(_ url: URL) throws -> WAVInfo? }`（`repairHeader` はファイル長からサイズ欄を書き直す。44 バイト未満なら nil）
  - `public struct WAVSegmentWriter { public static let segmentSeconds: Double = 300; public init(track: Track, meetingDirectory: URL, segmentSeconds: Double = WAVSegmentWriter.segmentSeconds); public mutating func open(at start: TimelineTime) throws -> [SegmentChange]; public mutating func write(_ chunk: AudioChunk) throws -> [SegmentChange]; public mutating func close(at end: TimelineTime) throws -> [SegmentChange]; public var isOpen: Bool { get } }`
  - `public enum SegmentChange: Equatable, Sendable { case opened(TrackFile); case closed(TrackFile) }`
  - ファイル名: `tracks/<track>-<NNN>.wav`（`NNN` は会議内でトラックごとの通し番号 000 から。一時停止をまたいでも続ける）。`TrackFile.relativePath` は会議ディレクトリからの相対パス。`opened` の `durationSeconds` は nil、`closed` は書いたサンプル数 ÷ 16000。開いていないときの `close` は `[]`（一時停止中の停止で呼ばれる）、`write` は `WAVSegmentWriterError.notOpen`

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct WAVSegmentWriterTests {
    @Test func writes16kMono16bit() throws {
        let dir = try TemporaryDirectory.make()
        var w = WAVSegmentWriter(track: .mic, meetingDirectory: dir)
        _ = try w.open(at: .init(seconds: 0)); _ = try w.write(AudioFixtures.tone(start: 0, seconds: 2))
        let closed = try w.close(at: .init(seconds: 2))
        #expect(closed == [.closed(TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .init(seconds: 0), durationSeconds: 2))])
        let info = try WAVFile.info(dir.appending(path: "tracks/mic-000.wav"))
        #expect(info.sampleRate == 16_000 && info.channels == 1 && info.bitsPerSample == 16 && info.durationSeconds == 2)
    }
    @Test func splitsEveryFiveMinutes() throws { /* segmentSeconds 300 のまま、tone を 1 秒ずつ 301 回 write 変化: opened(000, 0) → closed(000, 300) → opened(001, startOffset 300) → close で closed(001, 1) */ }
    @Test func fillsGapWithSilenceAndPadsTail() throws { /* open(0) → tone(0..1) → tone(3..4) → close(at: 6) → 長さ 6.0、サンプル[16000..<48000] がすべて 0、[48000..<64000] が 1000 */ }
    @Test func reopenAfterPauseStartsNewSegmentAtResumeTime() throws { /* open(0) → tone(0..10) → close(at: 10) → open(at: 20) → tone(20..25) → close(at: 25) 2 本目は "tracks/mic-001.wav"、startOffset 20、duration 5 */ }
    @Test func writeWhenClosedThrows() { /* open 前の write は WAVSegmentWriterError.notOpen */ }
}
@Suite struct WAVFileTests {
    @Test func repairsZeroSizedHeader() throws { /* header(dataBytes: 0) ＋ 32000 バイトのデータを書いたファイル → repairHeader の durationSeconds == 1.0、 その後 AVAudioFile(forReading:) の length == 16000 */ }
    @Test func repairReturnsNilForTruncatedFile() throws { /* 20 バイトのファイル → nil */ }
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter WAVSegmentWriterTests` と `--filter WAVFileTests` → Expected: FAIL（未定義）
- [ ] **Step 3: Implement**

`FileHandle` に追記し、ヘッダのサイズ欄は `close` と分割時に書き直す（途中のクラッシュは Task 12 の `repairHeader` で直す）。`TimelineAligner` を内部に持ち、`open(at:)` で作り直す。無音は 1 秒分の 0 配列を使い回して書く（長い穴でも一度に大きな配列を作らない）。分割境界はサンプル数で決め（300 × 16000）、境界をまたぐチャンクは分けて書く。
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter WAVSegmentWriterTests` と `--filter WAVFileTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/WAVFile.swift Sources/AutoNoteCore/Audio/WAVSegmentWriter.swift Tests/AutoNoteCoreTests/Audio/ && git commit -m "feat: add segmented WAV writer"`

### Task 6: 分割ファイルの結合（確定版文字起こしの前段）

要件書 §5.2「確定版文字起こしの前に結合する」。結合は計画 04 の `transcribe` 段階が呼ぶ。一時停止の区間は無音で埋めず、そこでファイルを分ける（長い無音を whisper に渡さないため。`BatchTranscriber` は呼び手が `startOffset` を足す約束なので、複数ファイルでも時刻は保たれる）。

**Files:**
- Create: `Sources/AutoNoteCore/Audio/SegmentMerger.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/SegmentMergerTests.swift`

**Interfaces:**
- Consumes: `WAVFile`、`WAVSegmentWriter`（テストでの作成）、`Manifest`、`TrackFile`
- Produces: `public enum SegmentMerger { public static func merge(_ manifest: Manifest, track: Track, meetingDirectory: URL) throws -> [TrackFile] }`。出力は `merged/<track>-<n>.wav`（n は 0 から）。前の終わり（`startOffset + durationSeconds`）と次の `startOffset` の差が `TimelineAligner.tolerance` 以内なら同じファイルにつなぐ。`durationSeconds` が nil の分割は `WAVFile.info` で長さを読む

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct SegmentMergerTests {
    @Test func joinsContiguousSegments() throws { /* writer で 0..300 と 300..310 の 2 分割を作った manifest → merge(.mic) が 1 件、 relativePath "merged/mic-0.wav"、startOffset 0、duration 310、サンプルは 2 ファイルの連結と一致 */ }
    @Test func splitsAtPause() throws { /* 0..10 と 20..30 → 2 件、startOffset 0 と 20、各 duration 10 */ }
    @Test func ignoresOtherTrackAndEmpty() throws { /* system だけの manifest で merge(.mic) → [] */ }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter SegmentMergerTests` → Expected: FAIL
- [ ] **Step 3: Implement `SegmentMerger.merge`**（`startOffset` 順に並べ、データ部をコピーしてヘッダを最後に書く）
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter SegmentMergerTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/SegmentMerger.swift Tests/AutoNoteCoreTests/Audio/SegmentMergerTests.swift && git commit -m "feat: merge contiguous WAV segments"`

### Task 7: 無音検知

**Files:**
- Create: `Sources/AutoNoteCore/Audio/SilenceMonitor.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/SilenceMonitorTests.swift`

**Interfaces:**
- Consumes: `AudioChunk`、`AudioLevel`、`Track`、`TimelineTime`
- Produces: `public struct SilenceMonitor: Sendable { public static let micWindowSeconds: Double = 15; public static let systemWindowSeconds: Double = 60; public static let nearSilencePeakDBFS: Double = -60; public static let micMessage: String; public static let systemMessage: String; public init(start: TimelineTime); public mutating func observe(_ track: Track, chunk: AudioChunk); public mutating func tick(now: TimelineTime, paused: Bool) -> [SilenceWarning] }`、`public struct SilenceWarning: Equatable, Sendable { public var track: Track; public var message: String }`

文言（要件書 §5.7 のまま）:
- `micMessage` = `"マイクが無音です。機材と許可を確認してください"`
- `systemMessage` = `"システム音声が届いていません。システム音声の録音許可と、会議アプリの音が出ているかを確認してください"`

判定（一時停止中の時間は数えない。`tick` の前回からの差を `paused == false` のときだけ足す）:
- マイク: 録音した時間が 15 秒に達した時点で、それまでのマイクのピークが −60 dBFS 未満（チャンクが一つも無い場合を含む）なら警告。判定はこの 1 回だけ
- システム音: 最後に「全サンプルが 0 ではないチャンク」を受けてから（無ければ録音開始から）の録音した時間が 60 秒に達したら警告。全サンプル 0 のチャンクは受信とみなさない（許可なしで無音のサンプルが届く場合も同じ文言で案内するため）
- それぞれ 1 回だけ返す

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct SilenceMonitorTests {
    @Test func micWarnsAt15sWhenSilent() {
        var m = SilenceMonitor(start: .init(seconds: 0))
        m.observe(.mic, chunk: AudioFixtures.zeros(start: 0, seconds: 15))
        #expect(m.tick(now: .init(seconds: 14.9), paused: false).isEmpty)
        #expect(m.tick(now: .init(seconds: 15), paused: false) == [.init(track: .mic, message: SilenceMonitor.micMessage)])
        #expect(m.tick(now: .init(seconds: 30), paused: false).isEmpty)
    }
    @Test func micDoesNotWarnWithSignal() { /* tone(0..1) を観測 → 15 秒で警告なし、以後も出ない */ }
    @Test func systemWarns60sAfterLastCallback() { /* tone(system, 0..1) → tick(60.9) 空 → tick(61) で system 警告 1 回 */ }
    @Test func allZeroSystemChunkDoesNotCountAsReceived() { /* zeros を受け続けても 60 秒で警告 */ }
    @Test func pausedTimeIsNotCounted() { /* tick(10, false) → tick(100, true)（一時停止）→ tick(149, false) は空 → tick(160, false) で mic・system とも警告 */ }
    @Test func messagesMatchSpec() {
        #expect(SilenceMonitor.micMessage == "マイクが無音です。機材と許可を確認してください")
        #expect(SilenceMonitor.systemMessage == "システム音声が届いていません。システム音声の録音許可と、会議アプリの音が出ているかを確認してください")
    }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter SilenceMonitorTests` → Expected: FAIL
- [ ] **Step 3: Implement `SilenceMonitor`**
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter SilenceMonitorTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/SilenceMonitor.swift Tests/AutoNoteCoreTests/Audio/SilenceMonitorTests.swift && git commit -m "feat: add per-track silence monitor"`

### Task 8: システム音（ProcessTapSource）

**Files:**
- Create: `Sources/AutoNoteCore/Audio/TapHardware.swift`, `Sources/AutoNoteCore/Audio/ProcessTapSource.swift`, `Sources/AutoNoteCore/Audio/AudioSourceError.swift`
- Create: `Sources/AutoNoteTestSupport/FakeTapHardware.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/ProcessTapSourceTests.swift`

**Interfaces:**
- Consumes: `AudioRingBuffer`、`SampleConverter`、`MeetingClock`、`AudioSource`、`AudioChunk`
- Produces:
  - `public struct TapSpec: Sendable, Equatable { public var excludeBundleIDs: [String]; public var isPrivate: Bool = true; public var muted: Bool = false }`
  - `public enum AggregateLayout: Sendable { case tapOnly, withOutputClock }`（既定は Task 1 の結果。`tapOnly` で受信できた場合 `tapOnly`）
  - `public protocol TapHardware: Sendable { func createTap(_ spec: TapSpec) throws -> (id: AudioObjectID, uuid: String); func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription; func defaultOutputDeviceUID() throws -> String; func createAggregate(_ description: [String: any Sendable]) throws -> AudioObjectID; func createIOProc(_ device: AudioObjectID, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock) throws -> AudioDeviceIOProcID; func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws; func stop(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws; func destroyIOProc(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID) throws; func destroyAggregate(_ device: AudioObjectID) throws; func destroyTap(_ tap: AudioObjectID) throws }`、本番は `public struct CoreAudioTapHardware: TapHardware`
  - `public enum AudioSourceError: Error, Equatable, Sendable { case coreAudio(call: String, status: OSStatus); case microphonePermission(MicrophonePermissionStatus); case deviceNotFound(uid: String); case alreadyStarted; case unsupportedFormat }`、`public enum MicrophonePermissionStatus: String, Sendable, Equatable { case authorized, denied, notDetermined, restricted }`（Task 9 が使う。同じファイルに置く）
  - `public struct SourceStatistics: Sendable, Equatable { public var callbacks: Int; public var frames: Int; public var droppedFrames: Int }`
  - `public actor ProcessTapSource: AudioSource { public nonisolated let track: Track /* = .system */; public init(clock: MeetingClock, hardware: any TapHardware = CoreAudioTapHardware(), excludeBundleIDs: [String] = [Bundle.main.bundleIdentifier].compactMap { $0 }, layout: AggregateLayout = .tapOnly, stopTimeout: Duration = .seconds(5)); public func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws; public func stop() async; public func statistics() -> SourceStatistics; public static let aggregateUIDPrefix = "com.yutaokoshi.autonote.tap."; public static func aggregateDescription(tapUUID: String, layout: AggregateLayout, outputUID: String?) -> [String: any Sendable] }`
  - TestSupport: `public final class FakeTapHardware: TapHardware, @unchecked Sendable { public var calls: [String] { get }; public var lastTapSpec: TapSpec? { get }; public var failOn: String?; public var teardownDelay: Duration; public var format: AudioStreamBasicDescription /* 既定 48k/2ch/Float32 interleaved */; public func fire(frames: Int, hostTime: UInt64, sampleTime: Double, value: Float) }`（`fire` は登録された IOProc ブロックを、組み立てた `AudioBufferList` と `AudioTimeStamp` で呼ぶ）

Core Audio の呼び出し順（スパイクで動いた順。`CoreAudioTapHardware` と `start`/`stop` はこの順を守る）:
1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` を作り、自アプリを除外（§5.1）: macOS 26 の bundle ID 指定（`CATapDescription` の bundle ID の配列と除外指定。SDK で正確なプロパティ名を確かめる）に `excludeBundleIDs` を入れる。無い場合は `kAudioHardwarePropertyTranslatePIDToProcessObject` で自プロセスの AudioObjectID を求めて除外配列に入れる。`isPrivate = true`、`muteBehavior = .unmuted`
2. `AudioHardwareCreateProcessTap` → tap の UUID は `desc.uuid.uuidString`
3. `kAudioTapPropertyFormat` を読む（Intel 内蔵スピーカーで 48000/2ch/Float32/interleaved）
4. `withOutputClock` のときだけ既定出力の UID（`kAudioHardwarePropertyDefaultSystemOutputDevice` → `kAudioDevicePropertyDeviceUID`）
5. `AudioHardwareCreateAggregateDevice`: Name、UID（`ProcessTapSource.aggregateUIDPrefix` ＋ 毎回新しい UUID。接頭辞は `"com.yutaokoshi.autonote.tap."`。overview §3）、`IsPrivate`=true、`IsStacked`=false、`TapAutoStart`=true、`TapList`=[[`SubTapUID`: tap UUID, `SubTapDriftCompensation`: true]]。`tapOnly` は `MainSubDevice` と `SubDeviceList` を入れない
6. `AudioDeviceCreateIOProcIDWithBlock`（ブロックは nonisolated な static 関数で作る。中身は `ring.write(inInputData, frameCount:, hostTime: inInputTime.mHostTime, sampleTime: inInputTime.mSampleTime)` だけ）
7. `AudioDeviceStart`
8. 停止: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct ProcessTapSourceTests {
    @Test func startCallsHardwareInOrder() async throws {
        let hw = FakeTapHardware(); let src = ProcessTapSource(clock: .fake(), hardware: hw, excludeBundleIDs: ["com.yutaokoshi.autonote"])
        try await src.start { _ in }
        #expect(hw.calls == ["createTap", "tapFormat", "createAggregate", "createIOProc", "start"])
        #expect(hw.lastTapSpec?.excludeBundleIDs == ["com.yutaokoshi.autonote"])
    }
    @Test func tapOnlyAggregateHasNoOutputDevice() {
        let d = ProcessTapSource.aggregateDescription(tapUUID: "T", layout: .tapOnly, outputUID: nil)
        #expect(d[kAudioAggregateDeviceSubDeviceListKey] == nil && d[kAudioAggregateDeviceMainSubDeviceKey] == nil)
        #expect(d[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true && d[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect((d[kAudioAggregateDeviceUIDKey] as? String)?.hasPrefix("com.yutaokoshi.autonote.tap.") == true)
    }
    @Test func failureMidwayTearsDownCreatedObjects() async {
        let hw = FakeTapHardware(); hw.failOn = "createAggregate"
        await #expect(throws: AudioSourceError.self) { try await ProcessTapSource(clock: .fake(), hardware: hw).start { _ in } }
        #expect(hw.calls.suffix(1) == ["destroyTap"])
    }
    @Test func deliversConvertedChunks() async throws { /* fire を 48k の 480 フレーム × 100 回（1 秒、hostTime を 10 ms ずつ進める）→ stop → 受け取った samples 合計が 16000±48 */ }
    @Test func chunkStartFollowsHostTimeAcrossGap() async throws { /* 0 秒に 0.5 秒分、5 秒に 0.5 秒分を fire → 2 つ目の塊の最初のチャンクの start が 5.0±0.02 */ }
    @Test func stopReturnsWithinTimeoutWhenTeardownBlocks() async throws {
        let hw = FakeTapHardware(); hw.teardownDelay = .seconds(3)
        let src = ProcessTapSource(clock: .fake(), hardware: hw, stopTimeout: .milliseconds(200))
        try await src.start { _ in }
        let t0 = ContinuousClock.now; await src.stop()
        #expect(ContinuousClock.now - t0 < .seconds(1))
    }
    @Test @MainActor func stopFromMainActorDoesNotBlockMainThread() async throws { /* 上と同じ条件で MainActor から stop → 1 秒未満 */ }
    @Test func statisticsCountCallbacksAndDrops() async throws { /* fire 3 回 → callbacks 3、frames 1440 */ }
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter ProcessTapSourceTests` → Expected: FAIL
- [ ] **Step 3: Implement `TapHardware`、`CoreAudioTapHardware`、`ProcessTapSource`、`FakeTapHardware`**

- リングバッファは tap の形式に合わせて `start` で作る（容量 10 秒分、レコード 4096）
- 取り出しタスク（`Task.detached`、20 ms ごと）: `read` → 前のレコードとのホスト時刻の差が `TimelineAligner.tolerance` を超えたら `SampleConverter.reset()` → `convert` → `AudioChunk(track: .system, samples:, start: clock.timeline(hostTime: record.hostTime), hostTime:)` を `onBuffer` に渡す
- `stop`: 破棄 4 手順を専用の `DispatchQueue` で行い、`withCheckedContinuation` で待つ。`stopTimeout` を過ぎたら待つのをやめて `os.Logger` に `teardown timeout` を残して進む（破棄は裏で続く）。その後リングの残りと `flush()` を渡して取り出しタスクを終える
- 二重の `start` は `.alreadyStarted`
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter ProcessTapSourceTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/ Sources/AutoNoteTestSupport/FakeTapHardware.swift Tests/AutoNoteCoreTests/Audio/ProcessTapSourceTests.swift && git commit -m "feat: add process tap system audio source"`

### Task 9: マイク（MicrophoneSource）

**Files:**
- Create: `Sources/AutoNoteCore/Audio/MicrophoneEngine.swift`, `Sources/AutoNoteCore/Audio/MicrophoneSource.swift`, `Sources/AutoNoteCore/Audio/AudioDeviceLookup.swift`
- Create: `Sources/AutoNoteTestSupport/FakeMicrophoneEngine.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/MicrophoneSourceTests.swift`

**Interfaces:**
- Consumes: `AudioRingBuffer`、`SampleConverter`、`MeetingClock`、`AudioSourceError`、`MicrophonePermissionStatus`（Task 8）、`DeviceRef`
- Produces:
  - `public protocol MicrophonePermissionChecking: Sendable { func status() -> MicrophonePermissionStatus }`、`public struct AVMicrophonePermission: MicrophonePermissionChecking`（`AVCaptureDevice.authorizationStatus(for: .audio)`。要求はしない。要求は計画 06 の画面が行う）
  - `public struct InputFormat: Sendable, Equatable { public var sampleRate: Double; public var channels: Int }`、`public protocol MicrophoneEngine: AnyObject, Sendable { func prepare(deviceID: AudioDeviceID?, voiceProcessing: Bool) throws -> InputFormat; func start(writingTo ring: AudioRingBuffer) throws; func stop() }`、本番 `public final class AVMicrophoneEngine: MicrophoneEngine, @unchecked Sendable`
  - `public protocol AudioDeviceLookup: Sendable { func deviceID(forUID uid: String) -> AudioDeviceID?; func deviceRef(forUID uid: String?) -> DeviceRef? }`（nil は既定入力。`DeviceRef.transport` は overview §3 の小文字の値 `builtin` `bluetooth` `usb` `aggregate` `virtual` `unknown` に変換する）、本番 `public struct CoreAudioDeviceLookup: AudioDeviceLookup`
  - `public actor MicrophoneSource: AudioSource { public nonisolated let track: Track /* = .mic */; public init(deviceUID: String?, clock: MeetingClock, voiceProcessing: Bool = false, permission: any MicrophonePermissionChecking = AVMicrophonePermission(), engine: any MicrophoneEngine = AVMicrophoneEngine(), lookup: any AudioDeviceLookup = CoreAudioDeviceLookup()); public func start(onBuffer: @Sendable @escaping (AudioChunk) -> Void) async throws; public func stop() async }`
  - TestSupport: `public final class FakeMicrophoneEngine: MicrophoneEngine, @unchecked Sendable { public var prepared: (deviceID: AudioDeviceID?, voiceProcessing: Bool)?; public var format: InputFormat; public func push(frames: Int, hostTime: UInt64, value: Float) }`、`public struct FakeMicrophonePermission: MicrophonePermissionChecking`、`public struct FakeDeviceLookup: AudioDeviceLookup`

`AVMicrophoneEngine` の手順（MicHotSwap で動いた順）: `AVAudioEngine()` → `voiceProcessing` なら `inputNode.setVoiceProcessingEnabled(true)`（デバイス設定より先）→ `deviceID` があれば `inputNode.audioUnit` に `kAudioOutputUnitProperty_CurrentDevice` → `inputNode.outputFormat(forBus: 0)` を `InputFormat` で返す → `start` で `installTap(onBus: 0, bufferSize: 4096, format:)`（ブロックは nonisolated な関数で作り、`ring.write(buffer.audioBufferList, frameCount:, hostTime: when.hostTime, sampleTime: Double(when.sampleTime))` だけを行う）→ `prepare()` → `start()`。UID → ID は `kAudioHardwarePropertyTranslateUIDToDevice`（無い UID は `kAudioObjectUnknown`）。

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct MicrophoneSourceTests {
    @Test(arguments: [MicrophonePermissionStatus.notDetermined, .denied, .restricted])
    func refusesWithoutPermissionAndNeverTouchesEngine(status: MicrophonePermissionStatus) async {
        let engine = FakeMicrophoneEngine()
        let src = MicrophoneSource(deviceUID: nil, clock: .fake(), permission: FakeMicrophonePermission(status), engine: engine, lookup: FakeDeviceLookup())
        await #expect(throws: AudioSourceError.microphonePermission(status)) { try await src.start { _ in } }
        #expect(engine.prepared == nil)
    }
    @Test func resolvesDeviceUIDAndPassesVoiceProcessing() async throws { /* FakeDeviceLookup に "USB-MIC:input" → 77 を登録、voiceProcessing: true → engine.prepared == (77, true) */ }
    @Test func unknownUIDThrowsDeviceNotFound() async { /* "GONE:input" → .deviceNotFound(uid: "GONE:input")、prepare されない */ }
    @Test func nilUIDUsesDefaultInput() async throws { /* engine.prepared?.deviceID == nil */ }
    @Test func voiceProcessingIsOffByDefault() async throws { /* engine.prepared?.voiceProcessing == false */ }
    @Test func deliversChunksAt16k() async throws { /* format 24000/1ch、push(24000 フレーム) → stop → samples 合計 16000±48、start は push の hostTime の会議時刻 */ }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter MicrophoneSourceTests` → Expected: FAIL
- [ ] **Step 3: Implement**（許可の確認 → UID 解決 → `prepare` → リング作成 → 取り出しタスク → `engine.start`。取り出しは Task 8 と同じ規則。`stop` は `engine.stop()` を専用キューで呼び、Task 8 と同じくタイムアウト付きで待つ）
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter MicrophoneSourceTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/ Sources/AutoNoteTestSupport/ Tests/AutoNoteCoreTests/Audio/MicrophoneSourceTests.swift && git commit -m "feat: add microphone source with permission gate"`

### Task 10: RecordingSession（開始・一時停止・ブックマーク・停止・短すぎる録音・マイクの付け外し）

**Files:**
- Create: `Sources/AutoNoteCore/Audio/AudioSourceFactory.swift`, `Sources/AutoNoteCore/Audio/RecordingSession.swift`, `Sources/AutoNoteCore/Audio/RecordingEvent.swift`
- Create: `Sources/AutoNoteTestSupport/FakeAudioSourceFactory.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/RecordingSessionTests.swift`, `Tests/AutoNoteCoreTests/Audio/SessionHarness.swift`

**Interfaces:**
- Consumes: `AudioSource`、`ProcessTapSource`、`MicrophoneSource`、`WAVSegmentWriter`、`SegmentChange`、`SilenceMonitor`、`MeetingClock`、`HostClock`、`AppPaths`、`ManifestStore`、`Settings.voiceProcessing`（`live` だけ）、`Manifest` ほか §3 の型
- Produces（計画 03・06 が使う完全なシグネチャ）:

```swift
public protocol AudioSourceFactory: Sendable {
    func makeSystemSource(clock: MeetingClock) -> any AudioSource
    func makeMicrophoneSource(deviceUID: String?, clock: MeetingClock) -> any AudioSource
    func inputDevice(uid: String?) -> DeviceRef?          // manifest.device 用。nil = 既定入力
}
public struct LiveAudioSourceFactory: AudioSourceFactory {
    public let voiceProcessing: Bool
    public init(voiceProcessing: Bool = false, tapLayout: AggregateLayout = .tapOnly)
}

public enum StopReason: String, Sendable, Equatable { case manual, deviceGone, diskFull, appTerminating }
public enum SessionState: Sendable, Equatable { case idle, recording(MeetingID), paused(MeetingID) }
public struct TrackStatistics: Sendable, Equatable { public var chunks: Int; public var samples: Int; public var peakDBFS: Double }
public enum RecordingError: Error, Equatable, Sendable {
    case alreadyRecording, notRecording, notPaused, alreadyPaused
    case microphonePermission(MicrophonePermissionStatus)
    case insufficientDiskSpace(availableBytes: Int64)
    case allSourcesFailed(String)
}
public enum RecordingEvent: Sendable, Equatable {
    case started(MeetingID)
    case paused(TimelineTime)
    case resumed(TimelineTime)
    case bookmarked(Bookmark)
    case silenceWarning(SilenceWarning)
    case diskSpaceLow(availableBytes: Int64)
    case sourceFailed(Track, message: String)
    case microphoneDetached(TimelineTime)
    case microphoneAttached(TimelineTime, device: DeviceRef?)
    case stopped(Manifest, StopReason)
}

public actor RecordingSession {
    public struct Configuration: Sendable, Equatable {
        public var language: Language
        public var microphoneUID: String?     // nil = 既定入力（手動開始、要件書 §5.1）
        public var device: DeviceRef?         // 起点機材。nil なら sources.inputDevice(uid: microphoneUID)
        public init(language: Language, microphoneUID: String? = nil, device: DeviceRef? = nil)
    }
    public static let minimumDurationSeconds: Double = 60
    public init(paths: AppPaths, manifests: ManifestStore, sources: any AudioSourceFactory,
                host: any HostClock = MachHostClock(), disk: any DiskSpaceProvider = SystemDiskSpace(),
                now: @escaping @Sendable () -> Date = { Date() }, tickInterval: Duration = .seconds(1))
    /// アプリ用の組み立て（計画 03・06 の `AppEnvironment.make` が使う）。実機の tap とマイク、`ManifestStore(paths:)`、`SystemDiskSpace()`、
    /// `LiveAudioSourceFactory(voiceProcessing: settings.voiceProcessing)` で組む。`clock` はホスト時計（会議ごとの `MeetingClock` は `start` で作る）
    public static func live(paths: AppPaths, settings: Settings, clock: any HostClock = MachHostClock()) -> RecordingSession
    public func events() -> AsyncStream<RecordingEvent>                   // 呼ぶたびに新しい購読。全購読者に同じ事象を流す（overview §8b）
    public var state: SessionState { get }
    public func elapsed() -> TimelineTime
    public func start(_ configuration: Configuration) async throws -> MeetingID
    public func pause() async throws
    public func resume() async throws
    @discardableResult public func bookmark(note: String? = nil) async throws -> Bookmark
    public func setLanguage(_ language: Language) async throws
    public func detachMicrophone() async throws                          // 計画 03: 起点機材の切断（猶予開始）
    public func attachMicrophone(deviceUID: String?) async throws        // 計画 03: 機材の復帰。失敗時は throw し、呼び手が nil（既定入力）で呼び直す
    public func stop(reason: StopReason = .manual) async throws -> Manifest
    public func audio(for track: Track) -> AsyncStream<AudioChunk>       // 計画 04 のリアルタイム供給。一時停止中は流さない。呼ぶたびに前の購読を終える
    public func statistics() -> [Track: TrackStatistics]
}
```

（`DiskSpaceProvider` と `SystemDiskSpace` は Task 11 で中身を作る。本タスクでは protocol と「常に十分」を返す既定だけを `DiskSpace.swift` に置く。）

振る舞い:
- `start`: 状態確認 → `MeetingID.make(start: now())` → `MeetingClock(origin: host.hostTime())` → manifest（`status .recording`、`source .live`、`device`、`language`、`silenceWarning false`、`autonoteVersion AutoNoteVersion.current`）を保存 → 両トラックの `WAVSegmentWriter.open(at: 0)` → マイク、システムの順に `start`。マイクの `.microphonePermission` は録音を始めずに後始末（会議ディレクトリを消す）して同じ値の `RecordingError` を throw。それ以外の片方の失敗は `.sourceFailed` を出し、`silenceWarning = true` にして続ける。両方失敗なら後始末して `.allSourcesFailed`
- `events()`: 購読ごとに `AsyncStream.makeStream()` で continuation を作り、`[UUID: AsyncStream<RecordingEvent>.Continuation]` に登録する。事象は登録中の全員に yield し、`onTermination` で登録を外す。購読より前の事象は流さない
- 音源の `onBuffer` は `AsyncStream<(Track, AudioChunk)>` に yield し、セッション内の 1 本のタスクが順に `SilenceMonitor.observe` → 一時停止中でなければ `writer.write` → `audio(for:)` の購読者へ、と処理する（到着順を保つ。`Task {}` を chunk ごとに作らない）
- `pause`: `pauses` に `PauseInterval(start: now, end: nil)`、両トラック `close(at: now)`。一時停止中のチャンクは捨てる。`resume`: `end` を埋め、両トラック `open(at: now)`
- `bookmark`: 録音中・一時停止中に可。`Bookmark(at: elapsed(), note:)` を manifest に足す
- `detachMicrophone`: マイク音源を `stop`（マイクの writer は開いたまま。続きは `attachMicrophone` 後のチャンクか停止時の `close(at:)` が無音で埋める、要件書 §11.5）。`attachMicrophone`: 新しいマイク音源を `start`
- `stop`: 両音源を `stop`（各音源が自分のタイムアウトで戻る）→ キューを処理し切る → 開いている pause を閉じる → 両トラック `close(at: end)` → `endedAt = startedAt + end`、`status = end < 60 秒 ? .tooShort : .recorded` → 保存 → `.stopped` を出して `state = .idle`
- manifest は `SegmentChange`（opened は追加、closed は同じ `relativePath` を置き換え）、pause、bookmark、言語、無音警告のたびに保存する

- [ ] **Step 1: Write the failing test**

`SessionHarness.make()` は一時ディレクトリの `AppPaths`、`ManifestStore`、`FakeAudioSourceFactory`（`mic` と `system` の `FakeAudioSource` を持つ）、`FakeHostClock`、固定の `now`、`FakeDiskSpace`（既定 100GB。Task 11 で `make(disk:)` から渡す）で `RecordingSession` を作り、`duration(_ m: Manifest, _ track: Track)`（そのトラックの WAV の合計秒）を持つ。チャンクを流した後は `await session.waitUntilIdle()`（`internal`、`@testable` で呼ぶ）で処理を待つ。

```swift
@Suite struct RecordingSessionTests {
    @Test func startWritesRecordingManifest() async throws {
        let h = try await SessionHarness.make()
        let id = try await h.session.start(.init(language: .ja, device: DeviceRef(name: "Test Mic", uid: "TEST:input", transport: "usb")))
        let m = try await h.manifests.load(id)
        #expect(m.status == .recording && m.source == .live && m.language == .ja && m.device?.uid == "TEST:input")
        #expect(await h.session.state == .recording(id))
    }
    @Test func systemTrackIsPaddedToMicLength() async throws {
        let h = try await SessionHarness.make(); _ = try await h.session.start(.init(language: .ja))
        await h.mic.emit(AudioFixtures.tone(start: 0, seconds: 12))
        await h.system.emit(AudioFixtures.tone(start: 0, seconds: 1)); await h.system.emit(AudioFixtures.tone(start: 10, seconds: 1))
        h.clock.advance(12); let m = try await h.session.stop()
        #expect(abs(try h.duration(m, .system) - 12) < 0.05 && abs(try h.duration(m, .mic) - 12) < 0.05)
    }
    @Test func pauseSkipsAudioAndRecordsInterval() async throws { /* 0..10 を流す → advance 10 → pause → 10..20 を流す（捨てられる）→ advance 10 → resume → 20..25 → advance 5 → stop pauses == [PauseInterval(start: 10, end: 20)]、mic の TrackFile は startOffset 0（10 秒）と 20（5 秒） */ }
    @Test func bookmarkUsesTimelineAndWorksWhilePaused() async throws { /* advance 5 → bookmark("決定") → pause → advance 3 → bookmark(nil) → bookmarks の at が 5 と 8 */ }
    @Test(arguments: [(59.9, MeetingStatus.tooShort), (60.0, .recorded)])
    func shortRecordingIsMarkedTooShort(seconds: Double, expected: MeetingStatus) async throws { /* advance(seconds) → stop → status == expected、endedAt == startedAt + seconds */ }
    @Test func micPermissionDeniedRefusesToStart() async throws { /* factory の mic を startError: AudioSourceError.microphonePermission(.denied) に → start が RecordingError.microphonePermission(.denied)、system は start されない、recordings/ に会議が残らない、state == .idle */ }
    @Test func systemFailureContinuesWithMic() async throws { /* system を startError: AudioSourceError.coreAudio(call: "AudioHardwareCreateProcessTap", status: -1) → start は成功、events に .sourceFailed(.system, …)、manifest.silenceWarning == true、mic の WAV は書かれる */ }
    @Test func bothFailThrowsAllSourcesFailed() async throws { /* 両方 startError → .allSourcesFailed、会議ディレクトリ無し */ }
    @Test func detachThenAttachFillsMicWithSilence() async throws { /* mic 0..5 → advance 5 → detachMicrophone → advance 10 → attachMicrophone("NEW:input") → 新 mic に 15..20 → advance 5 → stop mic の合計 20 秒、サンプル[5s..<15s] が 0、factory が deviceUID "NEW:input" で作られた */ }
    @Test func audioStreamYieldsOnlyWhileRecording() async throws { /* audio(for: .mic) に録音中の 2 チャンクだけが来て、一時停止中のものは来ない */ }
    @Test func invalidTransitionsThrow() async throws { /* idle で pause/stop/bookmark → .notRecording、録音中に start → .alreadyRecording、録音中に resume → .notPaused、二重 pause → .alreadyPaused */ }
    @Test func setLanguageUpdatesManifest() async throws { /* .ja で開始 → setLanguage(.en) → manifest.language == .en */ }
    @Test func eventsReachEverySubscriber() async throws { /* events() を 2 回呼んで 2 人が購読 → start → bookmark → 両方のストリームが [.started(id), .bookmarked(b)] を受け取る。片方を cancel してももう片方に .stopped が届く */ }
    @Test func liveUsesVoiceProcessingSetting() async throws { /* voiceProcessing を true にした Settings() で RecordingSession.live → @testable で見た sources が LiveAudioSourceFactory で voiceProcessing == true（録音は始めない） */ }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter RecordingSessionTests` → Expected: FAIL（`RecordingSession` が未定義）
- [ ] **Step 3: Implement `AudioSourceFactory`、`LiveAudioSourceFactory`、`FakeAudioSourceFactory`、`RecordingEvent`、`RecordingSession`**（上の「振る舞い」のとおり。`FakeAudioSourceFactory` は作った音源と渡された `deviceUID` を記録する）
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter RecordingSessionTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/ Sources/AutoNoteTestSupport/FakeAudioSourceFactory.swift Tests/AutoNoteCoreTests/Audio/ && git commit -m "feat: add recording session with pause, bookmark and short-recording check"`

### Task 11: RecordingSession の監視（ディスク空き・無音警告）

**Files:**
- Modify: `Sources/AutoNoteCore/Audio/DiskSpace.swift`, `Sources/AutoNoteCore/Audio/RecordingSession.swift`
- Create: `Sources/AutoNoteTestSupport/FakeDiskSpace.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/RecordingSessionMonitorTests.swift`

**Interfaces:**
- Consumes: Task 10 の `RecordingSession`、`SilenceMonitor`
- Produces: `public protocol DiskSpaceProvider: Sendable { func availableBytes(for url: URL) throws -> Int64 }`、`public struct SystemDiskSpace: DiskSpaceProvider`（`volumeAvailableCapacityForImportantUsage`）、`RecordingSession.diskWarningBytes: Int64 = 1_000_000_000`、`RecordingSession.diskStopBytes: Int64 = 500_000_000`、`RecordingSession.diskCheckEverySeconds: Double = 10`。TestSupport: `public final class FakeDiskSpace: DiskSpaceProvider, @unchecked Sendable { public var bytes: Int64 }`。`RecordingSession` の `internal func tick() async`（本番は `tickInterval` ごとに呼ぶタスク、テストは直接呼ぶ）

振る舞い:
- `tick`: `SilenceMonitor.tick(now:paused:)` の警告ごとに `manifest.silenceWarning = true` を保存して `.silenceWarning` を出す（通知を出すのは計画 06。1 回だけになるのは `SilenceMonitor` が保証する）
- 10 秒ごと（会議タイムライン）に録音ディレクトリの空きを見る: 1GB 未満で `.diskSpaceLow` を 1 回、500MB 未満で `stop(reason: .diskFull)`（音声は残し、`status` は通常どおり `.recorded` / `.tooShort`。後処理へ回すのは計画 05 の待ち行列）
- `start` の時点で 500MB 未満なら録音を始めずに `.insufficientDiskSpace`

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct RecordingSessionMonitorTests {
    @Test func warnsOnceBelow1GB() async throws { /* bytes 2GB で開始 → 900MB にして advance 10 → tick → events に .diskSpaceLow(900_000_000) が 1 回。advance 10 → tick → 増えない */ }
    @Test func stopsBelow500MBAndKeepsAudio() async throws { /* mic 0..70 → advance 70 → bytes 400MB → tick → state == .idle、events に .stopped(_, .diskFull)、status == .recorded、mic WAV 70 秒 */ }
    @Test func refusesToStartBelow500MB() async throws { /* bytes 100MB → start が .insufficientDiskSpace(availableBytes: 100_000_000) */ }
    @Test func micSilenceWarningSetsManifestFlag() async throws { /* mic に zeros(0..15) → advance 15 → tick → .silenceWarning(.init(track: .mic, message: SilenceMonitor.micMessage))、manifest.silenceWarning == true */ }
    @Test func systemSilenceWarningAfter60sWithoutCallbacks() async throws { /* mic tone だけ流し続け advance 60 → tick → system の警告 1 回。さらに advance 60 → tick → 増えない */ }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter RecordingSessionMonitorTests` → Expected: FAIL
- [ ] **Step 3: Implement**（`SystemDiskSpace`、`tick`、`start` での事前確認、`tickInterval` ごとのタスク。タスクは `stop` で止める）
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter RecordingSession` → Expected: PASS（Task 10 のスイートも含めて）
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/ Sources/AutoNoteTestSupport/FakeDiskSpace.swift Tests/AutoNoteCoreTests/Audio/RecordingSessionMonitorTests.swift && git commit -m "feat: monitor disk space and silence during recording"`

### Task 12: クラッシュ復旧

要件書 §5.8。問い合わせの画面は計画 06。本タスクは列挙・復旧・破棄の API だけを作る。結合は確定版文字起こしの前に `SegmentMerger` で行うので（Task 6）、復旧は「録り終えた会議と同じ状態の manifest に直す」ところまでにする。

**Files:**
- Create: `Sources/AutoNoteCore/Audio/CrashRecovery.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/CrashRecoveryTests.swift`

**Interfaces:**
- Consumes: `ManifestStore.unfinishedRecordings()`・`save`・`delete`、`AppPaths`、`WAVFile.repairHeader`、`RecordingSession.minimumDurationSeconds`
- Produces: `public struct CrashRecovery: Sendable { public init(paths: AppPaths, manifests: ManifestStore); public func findInterrupted(excluding active: MeetingID? = nil) async throws -> [Manifest]; public func recover(_ id: MeetingID) async throws -> Manifest; public func discard(_ id: MeetingID) async throws }`。`findInterrupted` は `unfinishedRecordings()` から `excluding` を除いたもの。起動時（録音を始める前）に呼ぶ前提で、`excluding` は録音中の会議を誤って拾わないための保険

`recover` の規則: 各 `TrackFile` について、ファイルが無い・44 バイト未満・データ 0 なら manifest から外す。それ以外は `repairHeader` してから `durationSeconds` を埋める。終わり = 全トラックの `startOffset + durationSeconds` の最大（トラックが一つも無ければ 0）。開いた pause は `end = 終わり` で閉じる。`endedAt = startedAt + 終わり`、`status = 終わり < 60 ? .tooShort : .recorded`。保存して返す。

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct CrashRecoveryTests {
    @Test func findsOnlyRecordingStatus() async throws { /* status .recording / .recorded / .tooShort の 3 会議 → findInterrupted() は .recording の 1 件。excluding にその id → [] */ }
    @Test func recoverRepairsUnfinalizedHeader() async throws { /* writer で 0..300 を書いて閉じ、001 を 90 秒分書いてヘッダのサイズ欄を 0 に戻したファイルと、durationSeconds nil の manifest → recover: 001 の durationSeconds == 90、AVAudioFile で読める、status .recorded、endedAt == startedAt + 390 */ }
    @Test func dropsMissingAndEmptySegments() async throws { /* 存在しない 1 件と 44 バイトだけの 1 件が tracks から消える */ }
    @Test func closesOpenPause() async throws { /* pauses [start 30, end nil]、終わり 80 → end 80 */ }
    @Test func shortInterruptedRecordingBecomesTooShort() async throws { /* 終わり 20 秒 → .tooShort */ }
    @Test func discardDeletesMeetingDirectory() async throws { /* discard 後に会議ディレクトリが無く、manifests.all() にも無い */ }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter CrashRecoveryTests` → Expected: FAIL
- [ ] **Step 3: Implement `CrashRecovery`**
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter CrashRecoveryTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/CrashRecovery.swift Tests/AutoNoteCoreTests/Audio/CrashRecoveryTests.swift && git commit -m "feat: add crash recovery for interrupted recordings"`

### Task 13: 音声ファイルの取り込み

要件書 §10。確定版文字起こしと議事録生成だけを行う会議として manifest を作る。形は overview §3 の「取り込んだ音声の manifest」に従う。話者は下流が `source` で決めるので本計画は触らない。

**Files:**
- Create: `Sources/AutoNoteCore/Audio/AudioImporter.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/AudioImporterTests.swift`

**Interfaces:**
- Consumes: `AppPaths`、`ManifestStore`、`WAVFile`、`MeetingID.make(start:)`
- Produces: `public struct AudioImporter: Sendable { public static let supportedExtensions: Set<String> /* ["wav", "m4a", "mp3", "mp4"] */; public static let importDevice: DeviceRef /* name "import", uid "import", transport "import" */; public init(paths: AppPaths, manifests: ManifestStore); public func importFile(_ url: URL, startedAt: Date? = nil, language: Language, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Manifest }`、`public enum ImportError: Error, Equatable, Sendable { case unsupportedFormat(String); case noAudioTrack; case unreadable(String) }`

規則: 拡張子（小文字化）で受け付けを判定。`AVURLAsset` の音声トラックを `AVAssetReaderTrackOutput`（`kAudioFormatLinearPCM`、16000Hz、1ch、16bit、little-endian、非インターリーブなし）で読み、`tracksDirectory(id)/import-000.wav` に書く。`startedAt` が nil ならファイルの作成日時（`URLResourceValues.creationDate`、無ければ更新日時）。manifest: `source .imported`、`device importDevice`、`tracks [TrackFile(track: .mic, relativePath: "tracks/import-000.wav", startOffset: 0, durationSeconds: 長さ)]`、`pauses []`、`bookmarks []`、`status .recorded`（取り込みには「短すぎる録音」を適用しない）、`endedAt = startedAt + 長さ`。

- [ ] **Step 1: Write the failing test**

テスト用の音声はテストの中で合成して一時ディレクトリに書く（リポジトリに置かない）: wav は `AVAudioFile`（44.1kHz/2ch）、m4a は `AVAudioFile`（AAC 設定）、mp4 は `AVAssetWriter`（AAC の音声トラックだけ）。

```swift
@Suite struct AudioImporterTests {
    @Test(arguments: ["wav", "m4a", "mp4"])
    func importsTo16kMonoWAV(ext: String) async throws { /* 3 秒の 440Hz 正弦 → importFile(language: .ja) info: 16000 / 1ch / 16bit、durationSeconds 3.0±0.05（AAC の前後の詰め物を含めて） manifest: source .imported、device == DeviceRef(name: "import", uid: "import", transport: "import")、status .recorded、tracks == [TrackFile(track: .mic, relativePath: "tracks/import-000.wav", …)] */ }
    @Test func defaultsStartToFileCreationDate() async throws { /* 作成日時を 2026-10-20 10:00 に設定した wav → startedAt がその日時、id.rawValue の先頭が "20261020-1000-" */ }
    @Test func explicitStartOverridesCreationDate() async throws { /* startedAt 指定がそのまま入る */ }
    @Test func rejectsUnsupportedExtension() async { /* "notes.txt" → .unsupportedFormat("txt") */ }
    @Test func garbageFileIsUnreadable() async throws { /* テキストを書いた "broken.m4a" → .unreadable(_) か .noAudioTrack。recordings/ に会議が残らない */ }
    @Test func reportsProgressUpToOne() async throws { /* progress の最後の値が 1.0、値は単調増加 */ }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter AudioImporterTests` → Expected: FAIL
- [ ] **Step 3: Implement `AudioImporter`**（失敗時は作りかけの会議ディレクトリを消す。mp3 は自動テストしない。AVFoundation でエンコードできないため Task 15 の 👤 手順で確かめる）
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter AudioImporterTests` → Expected: PASS
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/AudioImporter.swift Tests/AutoNoteCoreTests/Audio/AudioImporterTests.swift && git commit -m "feat: import audio files as 16 kHz mono meetings"`

### Task 14: 開発用サブコマンド `dev record` と `dev import`

**Files:**
- Create: `Sources/AutoNoteCore/Audio/RecordingReport.swift`, `Sources/autonote/DevRecord.swift`, `Sources/autonote/DevImport.swift`
- Modify: `Sources/autonote/DevCommands.swift`（`record` と `import` を足す）
- Test: `Tests/AutoNoteCoreTests/Audio/RecordingReportTests.swift`

**Interfaces:**
- Consumes: `RecordingSession.live(paths:settings:clock:)`、`RecordingSession.Configuration`、`events()`、`statistics()`、`AVMicrophonePermission`、`AudioImporter`、`AppPaths(root:)`、`Settings`、`DevCommands.run(_:)`（計画 01）
- Produces:
  - `public struct RecordingReport: Codable, Equatable, Sendable { public struct TrackReport: Codable, Equatable, Sendable { public var track: String; public var files: Int; public var seconds: Double; public var chunks: Int; public var peakDbfs: Double? }; public var meetingId: String; public var manifest: String; public var status: String; public var micPermission: String; public var tracks: [TrackReport]; public var events: [String]; public static func make(manifest: Manifest, manifestURL: URL, meetingDirectory: URL, statistics: [Track: TrackStatistics], events: [RecordingEvent], micPermission: MicrophonePermissionStatus) throws -> RecordingReport; public func jsonLine() throws -> String }`（JSON キーは snake_case。`peakDbfs` は −∞ のとき null。`events` は `"started"` `"sourceFailed(system)"` `"silenceWarning(mic)"` のように case 名と Track だけ）
  - `autonote dev record --seconds <N> --out <dir> [--mic-uid <UID>] [--voice-processing] [--check-permission]`: `AppPaths(root: <dir>)` と `Settings()`（`--voice-processing` で `voiceProcessing = true`）で `RecordingSession.live` を組んで録り、`RecordingReport.jsonLine()` を標準出力に 1 行出す。終了コード 0 成功、3 マイク許可が `authorized` でない（エンジンを組まずに即終了）、1 その他。`--check-permission` は `{"mic_permission":"…"}` だけを出して 0
  - `autonote dev import <file> --out <dir> [--lang auto|ja|en] [--start <ISO8601>]`: 標準出力に `{"meeting_id":…,"manifest":…,"wav":…,"seconds":…}`。終了コード 0 / 1

- [ ] **Step 1: Write the failing test**

```swift
@Suite struct RecordingReportTests {
    @Test func summarizesTracksAndEvents() throws { /* mic 2 分割（0..300, 300..310）と system 1 分割（0..310）を writer で作った manifest、statistics、events [.started(id), .sourceFailed(.system, message: "x")] → tracks[0] == (track "mic", files 2, seconds 310)、events == ["started", "sourceFailed(system)"]、status == manifest.status.rawValue */ }
    @Test func jsonUsesSnakeCaseAndNullForSilence() throws { /* peakDBFS が −∞ の track → jsonLine() に "\"peak_dbfs\":null" と "\"meeting_id\":" と "\"mic_permission\":\"authorized\"" が含まれ、JSONSerialization で読める */ }
}
```
- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter RecordingReportTests` → Expected: FAIL（`RecordingReport` が未定義）
- [ ] **Step 3: Implement `RecordingReport`、`DevRecord.swift`、`DevImport.swift`、`DevCommands` への登録**

`dev record`: 先に `AVMicrophonePermission().status()` を見て `authorized` 以外なら exit 3（`AVAudioEngine` に触らない。要件書 §3.4）。`events()` を購読してから `start` → `Task.sleep(seconds)` → `stop` → `RecordingReport.make`。SIGINT では `stop(reason: .manual)` してから終わる。`dev import`: `AudioImporter.importFile`。
- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter RecordingReportTests && swift build --product autonote && say -o /tmp/an.aiff "テストです" && afconvert -f m4af -d aac /tmp/an.aiff /tmp/an.m4a && .build/debug/autonote dev import /tmp/an.m4a --out /tmp/an-imp` → Expected: PASS、`dev import` が exit 0 で `seconds` が 0 より大きい JSON を出す
- [ ] **Step 5: Commit** — `git add Sources/AutoNoteCore/Audio/RecordingReport.swift Sources/autonote/ Tests/AutoNoteCoreTests/Audio/RecordingReportTests.swift && git commit -m "feat: add dev record and dev import subcommands"`

### Task 15: 👤 実機での録音確認（後回し可）

Task 1 の観測が本体（リングバッファ・穴埋め・変換）でも成り立つことと、ボイスプロセッシング（スパイク項目 5）を確かめる。機材と利用者の手が要るので後回しにしてよい。後回しにした場合は Task 16 へ進み、報告に「Task 15 未実施」と書く。

**Files:**
- Modify: `docs/superpowers/research/2026-10-24-spike-results.md`（項目 3・5）、`docs/superpowers/specs/2026-10-24-autonote-design.md`（§5.6、§19 の項目 5）

**Interfaces:**
- Consumes: Task 14 の `autonote dev record` / `dev import`
- Produces: なし（記録だけ）

- [ ] **Step 1: 👤 利用者 — 内蔵スピーカーと BT 出力での穴埋め**

1. 内蔵スピーカー: `afplay` を 20 秒目から 10 秒だけ鳴らしながら `.build/debug/autonote dev record --seconds 70 --out /tmp/an-rec` → mic と system の `seconds` が 70±0.5、`status` が `recorded`、system の WAV を聞いて音が 20〜30 秒の位置にある
2. Shokz を出力にして 1 と同じ（Task 1 Step 7 の観測が本体でも穴埋めされることの確認）

Expected: 記録した値。BT の UID が出たら下 3 オクテットを伏せる
- [ ] **Step 2: 👤 利用者 — ボイスプロセッシングと mp3**

1. 内蔵スピーカーで音楽を流し、`dev record --seconds 20 --voice-processing --out /tmp/an-vp` と `--voice-processing` なしを録る。記録: 起動直後に音楽の音量が下がるか（ダッキング）、system の `chunks` が 0 にならず同時に録れるか、mic の WAV で音楽の回り込みが減ったか
2. 手元の mp3 を `autonote dev import <file>.mp3 --out /tmp/an-imp` → exit 0、WAV が 16000 Hz / 1 ch

Expected: 記録した値
- [ ] **Step 3: 結果を記録する**

結果表の項目 3 に Step 1 の結果、項目 5 に Step 2 の 1 の結果（スパイクの `--vpio` でなく本体の `--voice-processing` で測ったこと）を足す。要件書 §5.6 の「スパイク未実施のため仮」を結果で置き換え（既定オフは変えない。変える必要があると判断したら利用者に確認する）、§19 の項目 5 の状態を更新する。
- [ ] **Step 4: Commit** — `git add docs/superpowers/research/ docs/superpowers/specs/2026-10-24-autonote-design.md && git commit -m "docs: record on-device recording and voice processing checks"`

### Task 16: E2E 更新、全 PASS、コミット

**Files:**
- Modify: `scripts/e2e-check.sh`（`check_dev_record`、`check_dev_import` と `CHECKS` 配列）

**Interfaces:**
- Consumes: Task 14 の `autonote dev record` / `dev import`、計画 01 が足す `AUTONOTE_CLI`（`swift build` 済みの `autonote`。無ければ `.build/debug/autonote`）
- Produces: E2E 項目 `CURRENT="02.1 dev record で 5 秒の WAV と manifest"` と `CURRENT="02.2 dev import で m4a / wav を 16k mono WAV に"`（overview §7 の名前の付け方）

- [ ] **Step 1: E2E の確認項目を足す**

`scripts/e2e-check.sh` に 2 関数を足し、`CHECKS` の計画 01 の項目の後に入れる。どちらも `AUTONOTE_CLI` が実行できなければ SKIP:
- `check_dev_record`（02.1）: `"${AUTONOTE_CLI}" dev record --check-permission` の `mic_permission` が `authorized` でなければ SKIP（「マイク許可がない（責任プロセス: ターミナル）」）。`run_timeout 40 "${AUTONOTE_CLI}" dev record --seconds 5 --out "${WORK}/rec"` が exit 0、JSON の `status` が `tooShort`（`MeetingStatus.tooShort.rawValue`。5 秒は 1 分未満）、manifest ファイルがあり `plutil -extract status raw` が同じ、mic と system の `seconds` がともに 5.0±0.5（システム音はコールバックが無くても無音で埋まる）、`afinfo` で各 WAV が `16000 Hz`・`1 ch`・16 bit。PASS の説明に system の `chunks` を出す（0 は失敗にしない）
- `check_dev_import`（02.2）: `say -o "${WORK}/s.aiff" "テストです"` → `afconvert -f m4af -d aac` と `afconvert -f WAVE -d LEI16@44100` で m4a と wav を作る → それぞれ `"${AUTONOTE_CLI}" dev import … --out "${WORK}/imp" --start 2026-10-20T10:00:00+09:00` が exit 0、manifest の `source` が `imported`、`device.name` が `import`、`tracks.0.relative_path` が `tracks/import-000.wav`、出力 WAV が `afinfo` で 16000 Hz / 1 ch。`say` が無ければ SKIP
- [ ] **Step 2: E2E を全部回す** — Run: `scripts/build-app.sh && scripts/e2e-check.sh` → Expected: FAIL 0。02.1 はターミナルにマイク許可があれば PASS、無ければ SKIP。02.2 は PASS
- [ ] **Step 3: Commit** — `git add scripts/e2e-check.sh && git commit -m "test: add e2e checks for dev record and dev import"`
