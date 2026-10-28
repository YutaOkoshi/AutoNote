# AutoNote 計画 08: 窓分割バッチ文字起こし Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 停止後の whisper 一括文字起こしを、merged WAV を名目 10 分の窓に分けて 1 つずつ読む形に変え、音声分のメモリを録音長によらず「窓 1 本分」で一定にする（監査 P1）。

**Architecture:** `WAVFile` にサンプル数と範囲読みを足す。新しい純粋な型 `BatchWindowPlanner` が、サンプル数と範囲読みの closure から窓（読む範囲・セグメントを採る範囲）の列を作る。境目は名目の終端の手前で最も長い無音の中央、無ければ名目の終端で切って 5 秒ずつ重ね、セグメントは中点で帰属を決める。`WhisperBatchTranscriber` は窓ごとに Int16 を読み、Float にし、今の `offset_ms` 再開ループと `BatchGate` をそのまま窓の中で回し、時刻に窓の開始を足して集める。GUI（`LazyBatchTranscriber`）と CLI（`dev transcribe --engine whisper`）は同じ `WhisperBatchTranscriber` を通る。CLI は 16 kHz mono 16-bit でない入力を `AudioImporter` と同じ変換で一時 WAV にしてから渡す。

**Tech Stack:** Swift 6.3 / swift-tools-version 6.2 / Swift Testing / whisper.cpp（変えない）/ AVFoundation（`AVAssetReader`）/ bash（`scripts/e2e-check.sh`）/ python3 標準ライブラリ（E2E の合成 WAV）/ `/usr/bin/time -l`

**Spec:** `docs/superpowers/specs/2026-10-28-windowed-batch-transcription-design.md`（binding）。根拠: `docs/superpowers/research/2026-10-27-memory-audit-long-recordings.md` の「4. 停止後のバッチ」「C. バッチ whisper」「修正案 P1」。直前の裁定: `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md` §8i

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
- （§8i より）時間頼みのテストは `waitUntil`（`ContinuousClock` の期限つきポーリング）で書く。`for _ in` の固定回数ループは使わない
- （§8i より）E2E は常に `AUTONOTE_DATA_DIR` と `first_run_completed: true` で走る。項目 1 が `swift test` を回すので、E2E はマシンがアイドルのときに回す（wall-clock テストは負荷で落ちる）
- （設計書 §制約）whisper.cpp のビルド・バージョンは変えない。`whisper_full` の呼び方（`offset_ms`、スレッド数、言語、プロンプト）は窓の中で今と同じ。`WhisperContext.run` は 1 回の呼び出しのまま。`Transcript`・`minutes.json`・`manifest` の形式は変えない

## Review Focus

設計書から読み取れるが、設計書の決定 6 のテストだけでは引っかからず、利用者が踏みやすいもの。各行のテストは担当タスクに入れてある。

1. ヘッダの data サイズが 0 や実際より大きい WAV（クラッシュ後に修復しきれなかったファイル）で、窓の計画がファイルの外を読もうとして落ちる。サンプル数は実ファイルの長さで頭打ちにし、範囲読みも頭打ちにする（Task 1 `sampleCountClampsToFileLength`・`sampleCountUsesFileLengthWhenHeaderSizeIsZero`・`rangedReadClampsToFileEnd`）
2. 休憩などで窓がまるごと無音のとき、窓を飛ばしたり `no_speech` で失敗させたりせず、whisper に掛けたうえで幻覚のセグメントを無音判定で落とす（Task 3 `silentWindowIsStillDecodedAndYieldsNothing`）
3. セグメントの中点がちょうど切れ目に乗ると、両方の窓が採るか両方が捨てる。中点 == 切れ目は後の窓が採る（Task 2 `ownershipAtTheCutGoesToTheLaterWindow`）
4. 16 kHz mono 16-bit でない WAV が `WhisperBatchTranscriber` に届くと（変換を忘れた呼び手）、44.1 kHz のバイト列を 16 kHz として読んで意味のない文字起こしを返す。`TranscriptionError.invalidAudio` で止める（Task 3 `non16kMonoWAVIsInvalidAudio`）
5. 窓 1 の終わり際に録音が始まって `BatchGate` が閉じたとき、窓 2 を始めてしまい録音と whisper が同時に走る。窓の中の再開でも窓の先頭でも必ずゲートを待つ（Task 3 `pausedGateHoldsTheNextWindow`）

## 前提の相違と解いた曖昧さ

設計書は編集せず、次のとおり決める。

1. **探す範囲と同点**: 「名目の終端の手前 60 秒」は直前の切れ目から名目長を足した位置の手前 60 秒。最も長い無音が複数あれば**後ろ**（名目の終端に近い方）を採る。60 秒も型の引数（`lookback`）にする（テストで名目 20 秒にするため）。
2. **末尾のまとめ**: 「名目 10 分の後に残りが 2 分未満なら最後の窓にまとめる」は、切れ目からの残りが `nominal + tailMerge`（600 + 120 秒）**以下**なら最後の窓とする（ちょうど 12 分も 1 窓）。
3. **0 サンプルのファイル**: 今は whisper を 0 サンプルで 1 回呼んで空を返す。窓も 1 つ（`0..<0`）で同じ 1 回の呼び出しにする。
4. **重なりの読み**: 強制で切った切れ目のあとの窓は、それが最後の窓でも切れ目の 5 秒前から読む。読む範囲はファイルの端で頭打ち。
5. **進み具合の割り当て**: 窓 i の whisper の進捗 p を `(owned.lowerBound + p × owned.count) / 全サンプル数` に写す（今の単調化 `report` を通す）。GUI の見出しに割合は出さない（設計書 5 で作り手の裁量。今回は出さない）。
6. **ログの分**: 「文字起こし 窓 i/n（a 分 / b 分）」の a は窓が採る範囲の終わり、b は全長を、それぞれ分に直して四捨五入した整数。ログは注入する closure に渡し、既定は os `Logger`（category `WhisperBatchTranscriber`）、CLI は stderr。
7. **重複除去の単位**: `RepetitionFilter.clean` は窓ごとではなく、帰属と無音判定のあとで全窓のセグメントをつないだ列に 1 回かける（今と同じく、隣り合う同文を窓をまたいでも落とす）。
8. **偽の whisper の窓番号**: `FakeWhisperCore(windows:)` は、`offsetSeconds == 0` の呼び出しを新しい窓の始まりと数える（再開は必ず `offset > 0` で呼ぶので、テストでは窓と一致する）。
9. **CLI の `--max-seconds`**: 先頭だけを一時 WAV に写すのも範囲読みで 60 秒ずつ行い、全量をメモリに持たない。
10. **100 MB**: E2E の上限は 100 × 1024 × 1024 バイト（`/usr/bin/time -l` の `maximum resident set size` はバイト）。

## 設計書 → タスク対応表

| 設計書 | タスク | 固定するテスト |
|---|---|---|
| 決定 1（merged WAV の範囲読み、全量読みを消す） | Task 1・Task 3 | Task 1 全テスト、Task 3 `requestsCarryOnlyTheWindowSamples` |
| 決定 2（名目 10 分、無音の中央、5 秒重ね、中点、末尾 2 分、引数化） | Task 2 | Task 2 全テスト |
| 決定 3（時刻に窓の開始を足す） | Task 3 | Task 3 `hardCutOverlapsAndKeepsEachSegmentOnce`・`timesAreShiftedAndMonotonic` |
| 決定 4（無音判定は窓の PCM、無音の窓も whisper へ、no_speech を出さない） | Task 3 | Task 3 `silenceFilterUsesTheWindowPCM`・`silentWindowIsStillDecodedAndYieldsNothing` |
| 決定 5（窓ごとのログと取り消し） | Task 3 | Task 3 `logsOneLinePerWindow`・`cancellationDuringFirstWindowNeverStartsTheSecond` |
| 決定 6 (a)〜(d) | Task 3 | (a) `shortFileIsOneWindowWithAllSamples` (b) `silenceCutDoesNotOverlap` (c) `hardCutOverlapsAndKeepsEachSegmentOnce` (d) `timesAreShiftedAndMonotonic`。E2E 04.3 は Task 4・5 で回す |
| 決定 7（10 分と 60 分の max RSS 差 ≤ 100 MB） | Task 5 | E2E 08.1 |
| 決定 8（CLI の非 16 kHz 入力を一時 WAV に、`fileInput` のコピーを消す） | Task 4 | Task 4 `convertToMono16kWAVWritesSamplesAndHeader`、E2E 08.2・04.3 |
| 取り込み音声も同じ経路 | Task 3 | Task 3 `importedTrackRunsThroughWindows`（`FinalTranscriptionRunnerTests`） |

## ファイル構成

- Core（変更）: `Audio/WAVFile.swift`（Task 1）、`Transcription/Shared/SilenceDetector.swift`（Task 2）、`Transcription/Whisper/WhisperBatchTranscriber.swift`・`WhisperCore.swift`（コメントのみ）・`Transcription/Engines/TranscriberFactory.swift`（Task 3）、`Audio/AudioImporter.swift`（Task 4）
- Core（新規）: `Transcription/Whisper/BatchWindowPlanner.swift`（Task 2。`BatchWindow` と `BatchWindowPlanner`）
- TestSupport: `FakeWhisperCore.swift`（Task 3。`init(windows:delay:)`）
- CLI: `Sources/autonote/DevTranscribe.swift`（Task 4）
- E2E: `scripts/e2e-check.sh`（Task 4 で 08.2、Task 5 で 08.1）
- Docs: `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md` §8j（Task 5）

---

### Task 1: `WAVFile` のサンプル数と範囲読み

**Files:**
- Modify: `Sources/AutoNoteCore/Audio/WAVFile.swift`
- Test: `Tests/AutoNoteCoreTests/Audio/WAVFileTests.swift`

**Interfaces:**
- Consumes: なし
- Produces:
  - `public static func sampleCount(_ url: URL) throws -> Int` — 16-bit mono のサンプル数。`readSamples(_:)` と同じ規則: ヘッダの data サイズが 0 ならファイル長 − 44、そうでなければ `min(data サイズ, ファイル長 − 44)`、奇数バイトは切り捨てて 2 で割る。ヘッダが読めなければ `WAVFileError.invalidHeader`
  - `public static func readSamples(_ url: URL, in range: Range<Int>) throws -> [Int16]` — `range` を `0..<sampleCount` で頭打ちにして、その範囲だけを `FileHandle` で読む（空なら `[]`）
  - `readSamples(_ url:)` は `readSamples(url, in: 0..<sampleCount(url))` になる（`Data(contentsOf:)` の全量読みを消す。署名は変えない）

- [ ] **Step 1: 失敗するテストを書く**

```swift
private func ramp(_ n: Int, dataBytes: Int? = nil) throws -> URL {   // サンプル i の値が Int16(i)
    let url = try TemporaryDirectory.make().appending(path: "r.wav")
    var data = WAVFile.header(sampleRate: 16_000, channels: 1, bitsPerSample: 16, dataBytes: dataBytes ?? n * 2)
    (0..<n).map { Int16($0) }.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
    return url
}
@Test func sampleCountReadsTheHeader() throws { #expect(try WAVFile.sampleCount(try ramp(1000)) == 1000) }
@Test func sampleCountUsesFileLengthWhenHeaderSizeIsZero() throws { #expect(try WAVFile.sampleCount(try ramp(1000, dataBytes: 0)) == 1000) }
@Test func sampleCountClampsToFileLength() throws { #expect(try WAVFile.sampleCount(try ramp(1000, dataBytes: 64_000)) == 1000) }
@Test func sampleCountDropsAnOddTrailingByte()   // dataBytes 0 + 5 バイトの本体 → 2
@Test func sampleCountRejectsNonWAV()            // "not a wav" の 20 バイト → throws WAVFileError.invalidHeader
@Test func rangedReadMatchesSlice() throws {
    let url = try ramp(1000)
    #expect(try WAVFile.readSamples(url, in: 100..<350) == (100..<350).map { Int16($0) })
    #expect(try WAVFile.readSamples(url, in: 0..<1000) == (0..<1000).map { Int16($0) })
}
@Test func rangedReadClampsToFileEnd() throws {
    let url = try ramp(1000, dataBytes: 64_000)
    #expect(try WAVFile.readSamples(url, in: 900..<2000) == (900..<1000).map { Int16($0) })
    #expect(try WAVFile.readSamples(url, in: 2000..<3000).isEmpty)
}
```

- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter WAVFileTests` → Expected: `type 'WAVFile' has no member 'sampleCount'` でビルド失敗
- [ ] **Step 3: `WAVFile.swift` に上の 2 関数を実装し、`readSamples(_:)` を委譲にする** — ファイル長は `seekToEnd()` で取る。本体は `seek(toOffset: 44 + 2 × lower)` のあと最大 1 MiB ずつ `read(upToCount:)` して結果の `[Int16]` に直接コピーする（全体の `Data` を作らない）。足りずに EOF に当たったら読めた分で返す
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter 'WAVFileTests|SegmentMergerTests|PCMAudioTests|AudioImporterTests' && scripts/e2e-check.sh --quick` → Expected: PASS（既存の `readSamplesRoundTrips` を含む）、E2E 0 failed
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Audio/WAVFile.swift Tests/AutoNoteCoreTests/Audio/WAVFileTests.swift
git commit -m "feat(core): ranged WAV reads and sample count without loading the whole file" -m "<trailers>"
```

---

### Task 2: 窓の計画（`BatchWindowPlanner`）と最長の無音

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Whisper/BatchWindowPlanner.swift`
- Modify: `Sources/AutoNoteCore/Transcription/Shared/SilenceDetector.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/BatchWindowPlannerTests.swift`、`Tests/AutoNoteCoreTests/Transcription/SilenceDetectorTests.swift`

**Interfaces:**
- Consumes: なし（テストは `TestAudio.swift` の `tone(_:)`・`silence(_:)`）
- Produces:
  - `SilenceDetector.longestSilence(in samples: [Int16]) -> Range<Int>?` — `samples` の先頭を 0 とする 20 ms のフレーム格子で、RMS が `threshold` 未満のフレームが続く最長の連なりのサンプル範囲（フレーム境界にそろう）。長さが `minSilence` 未満なら nil。同じ長さなら後ろの連なり。末尾の端数フレームは数えない。既定の `SilenceDetector()`（0.01 / 0.8 秒）で使う
  - `public struct BatchWindow: Equatable, Sendable { public var index: Int; public var read: Range<Int>; public var owned: Range<Int>; public var isLast: Bool; public func owns(midpointSeconds m: Double) -> Bool }` — `read` は whisper に渡すサンプル範囲、`owned` はセグメントを採る範囲（ファイル先頭からのサンプル）。`owns` は `(index == 0 || m >= owned.lowerBound / 16 000) && (isLast || m < owned.upperBound / 16 000)`
  - `public struct BatchWindowPlanner: Sendable { public struct Config: Equatable, Sendable { public var nominal: Double; public var lookback: Double; public var overlap: Double; public var tailMerge: Double; public init(nominal: Double = 600, lookback: Double = 60, overlap: Double = 5, tailMerge: Double = 120) }; public init(config: Config = .init()); public func plan(sampleCount: Int, read: (Range<Int>) throws -> [Int16]) rethrows -> [BatchWindow] }`

`plan` の手順（秒はすべて ×16 000 してサンプルで扱う）:

```text
start = 0, previousWasHard = false
loop:
  readStart = previousWasHard ? max(0, start - overlap) : start
  if sampleCount - start <= nominal + tailMerge:
      最後の窓 read readStart..<sampleCount, owned start..<sampleCount, isLast true → 終わり
  nominalEnd = start + nominal
  search = (nominalEnd - lookback)..<nominalEnd
  if let s = SilenceDetector().longestSilence(in: read(search)):
      cut = search.lowerBound + (s.lowerBound + s.upperBound) / 2, hard = false, readEnd = cut
  else:
      cut = nominalEnd, hard = true, readEnd = min(sampleCount, cut + overlap)
  窓 read readStart..<readEnd, owned start..<cut, isLast false
  start = cut, previousWasHard = hard
```

- [ ] **Step 1: 失敗するテストを書く**

```swift
// SilenceDetectorTests に追加
@Test func longestSilenceFindsTheLongestRun() {
    #expect(SilenceDetector().longestSilence(in: tone(1) + silence(1) + tone(1) + silence(2) + tone(1)) == 48_000..<80_000)
}
@Test func longestSilenceIgnoresShortRuns()       // tone(1) + silence(0.78) + tone(1) → nil
@Test func longestSilencePrefersTheLaterOnTie()   // tone(1) + silence(1) + tone(1) + silence(1) + tone(1) → 48_000..<64_000

// BatchWindowPlannerTests
private let small = BatchWindowPlanner.Config(nominal: 20, lookback: 6, overlap: 5, tailMerge: 4)
private func plan(_ pcm: [Int16], _ c: BatchWindowPlanner.Config) -> [BatchWindow] {
    BatchWindowPlanner(config: c).plan(sampleCount: pcm.count) { Array(pcm[$0]) }
}
private func s(_ seconds: Double) -> Int { Int(seconds * 16_000) }

@Test func defaultsAreTheSpecValues() {
    #expect(BatchWindowPlanner.Config() == .init(nominal: 600, lookback: 60, overlap: 5, tailMerge: 120))
}
@Test func shortFileIsOneWindow() {
    #expect(plan(tone(18), small) == [BatchWindow(index: 0, read: 0..<s(18), owned: 0..<s(18), isLast: true)])
    #expect(plan(tone(24), small).count == 1)            // ちょうど nominal + tailMerge も 1 窓
    #expect(plan([], small) == [BatchWindow(index: 0, read: 0..<0, owned: 0..<0, isLast: true)])
}
@Test func cutsAtTheMiddleOfSilence() {               // 16–18 秒の無音 → 17 秒で切って重ねない
    #expect(plan(tone(16) + silence(2) + tone(22), small) == [
        BatchWindow(index: 0, read: 0..<s(17), owned: 0..<s(17), isLast: false),
        BatchWindow(index: 1, read: s(17)..<s(40), owned: s(17)..<s(40), isLast: true)])
}
@Test func longestSilenceInTheLookbackWins()          // tone(15)+silence(1)+tone(1)+silence(2)+tone(19) → 1 窓目の owned.upperBound == s(18)
@Test func silenceShorterThanMinimumIsAHardCut() {    // 0.5 秒の無音は無視 → 20 秒で強制、前は +5、後は −5
    #expect(plan(tone(17) + silence(0.5) + tone(22.5), small) == [
        BatchWindow(index: 0, read: 0..<s(25), owned: 0..<s(20), isLast: false),
        BatchWindow(index: 1, read: s(15)..<s(40), owned: s(20)..<s(40), isLast: true)])
}
@Test func remainderOverTheTailMergeMakesAThirdWindow() {   // 45 秒の tone → 20・40 で強制
    #expect(plan(tone(45), small).map(\.read) == [0..<s(25), s(15)..<s(45), s(35)..<s(45)])
    #expect(plan(tone(45), small).map(\.owned) == [0..<s(20), s(20)..<s(40), s(40)..<s(45)])
    #expect(plan(tone(43), small).count == 2)        // 残り 23 秒 ≤ 24 秒はまとめる
}
@Test func ownershipAtTheCutGoesToTheLaterWindow() {
    let w = plan(tone(40), small)
    #expect(w[0].owns(midpointSeconds: 19.99) && !w[0].owns(midpointSeconds: 20))
    #expect(w[1].owns(midpointSeconds: 20) && !w[1].owns(midpointSeconds: 19.99))
    #expect(w[1].owns(midpointSeconds: 1_000))       // 最後の窓は上限なし
}
```

- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter 'BatchWindowPlannerTests|SilenceDetectorTests'` → Expected: `cannot find 'BatchWindowPlanner' in scope` でビルド失敗
- [ ] **Step 3: `longestSilence(in:)` と `BatchWindowPlanner.swift` を実装する** — フレームの判定は `SilenceDetector` の既存の `isSpeechFrame` を使う（同じ基準 RMS 0.01・0.8 秒）。`plan` は上の手順のとおり。`Config` の値は秒、`lookback <= nominal` と `overlap < nominal` を `precondition` にする
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter 'BatchWindowPlannerTests|SilenceDetectorTests' && scripts/e2e-check.sh --quick` → Expected: PASS、E2E 0 failed
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Whisper/BatchWindowPlanner.swift Sources/AutoNoteCore/Transcription/Shared/SilenceDetector.swift \
    Tests/AutoNoteCoreTests/Transcription/BatchWindowPlannerTests.swift Tests/AutoNoteCoreTests/Transcription/SilenceDetectorTests.swift
git commit -m "feat(core): plan batch windows that cut at the longest silence or overlap by 5 s" -m "<trailers>"
```

---

### Task 3: `WhisperBatchTranscriber` が窓を 1 つずつ流す

**Files:**
- Modify: `Sources/AutoNoteCore/Transcription/Whisper/WhisperBatchTranscriber.swift`、`Sources/AutoNoteCore/Transcription/Engines/TranscriberFactory.swift`、`Sources/AutoNoteCore/Transcription/Whisper/WhisperCore.swift`（`WhisperRunRequest.samples` のコメントを「バッチの窓、またはライブの窓の 16 kHz mono」に直すだけ）、`Sources/AutoNoteTestSupport/FakeWhisperCore.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/WhisperBatchTranscriberTests.swift`、`Tests/AutoNoteCoreTests/Transcription/FinalTranscriptionRunnerTests.swift`

**Interfaces:**
- Consumes: `WAVFile.info(_:)`・`WAVFile.sampleCount(_:)`・`WAVFile.readSamples(_:in:)`（Task 1）、`BatchWindowPlanner`・`BatchWindow.owns(midpointSeconds:)`（Task 2）
- Produces:
  - `public init(core: any WhisperCore, gate: BatchGate, windows: BatchWindowPlanner.Config = .init(), log: @escaping @Sendable (String) -> Void = WhisperBatchTranscriber.systemLog)`
  - `public static let systemLog: @Sendable (String) -> Void` — `Logger(subsystem: "com.yutaokoshi.autonote", category: "WhisperBatchTranscriber").info` に `.public` で書く
  - `TranscriberFactory.whisperBatch(modelURL: URL, machine: MachineKind, gate: BatchGate, log: (@Sendable (String) -> Void)? = nil) throws -> any BatchTranscriber`（nil は `systemLog`。`makeBatch` は変えない）
  - `FakeWhisperCore.init(windows: [[WhisperSegment]], delay: Duration = .zero)` — 窓 k（k = その呼び出しまでの `offsetSeconds == 0` の呼び出しの数 − 1。再開の呼び出しは直前の窓のまま）の台本 `windows[k]`（範囲外は `[]`）。時刻は窓の先頭からの秒。出し方は `init(segments:)` と同じ（`start >= offsetSeconds` のものを順に、`delay` を挟み、各回のあと `shouldAbort`）

`transcribe` の流れ（今の `while true` の再開ループと `BatchGate` の扱いはそのまま窓の中へ移す）:
1. `WAVFile.info` が 16 000 Hz・1 ch・16 bit でなければ（ヘッダが読めない場合も）`TranscriptionError.invalidAudio("<ファイル名>: not a 16 kHz mono 16-bit WAV")`
2. `count = sampleCount`、`windows = BatchWindowPlanner(config:).plan(sampleCount: count) { try WAVFile.readSamples(file, in: $0) }`
3. 窓ごとに: `Task.checkCancellation()` → `pcm = readSamples(file, in: w.read)` → `samples = PCMAudio.floats(pcm)` → 再開ループ（オフセットは窓ごとに 0 から。窓の先頭でも `gate.waitIfPaused()`）→ 窓のセグメントのうち `SilenceDetector().hasSpeech(in: pcm, from: 窓内の start, to: 窓内の end)` かつ `w.owns(midpointSeconds: 窓の開始秒 + 中点)` のものを、`start/end` に `w.read.lowerBound / 16 000` を足して集める → ログ 1 行 → 次の窓へ（`pcm`・`samples` はここで手放す）
4. 全窓のあとで `report(1.0)`、`RepetitionFilter.clean` を 1 回、今と同じ `Utterance` に変換

- [ ] **Step 1: 失敗するテストを書く**

```swift
private let small = BatchWindowPlanner.Config(nominal: 20, lookback: 6, overlap: 5, tailMerge: 4)
private func seg(_ a: Double, _ b: Double, _ t: String) -> WhisperSegment { .init(start: a, end: b, text: t) }
private func run(_ core: FakeWhisperCore, _ pcm: [Int16], gate: BatchGate = BatchGate(),
                 log: @escaping @Sendable (String) -> Void = { _ in },
                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Utterance] {
    try await WhisperBatchTranscriber(core: core, gate: gate, windows: small, log: log)
        .transcribe(file: try wavFile(pcm), language: .ja, hints: [], progress: progress)
}

@Test func shortFileIsOneWindowWithAllSamples() async throws {                 // 決定 6 (a)
    let core = FakeWhisperCore(windows: [[seg(0, 23, "一")]])
    #expect(try await run(core, tone(23)).map(\.text) == ["一"])
    #expect(core.requests.map(\.samples.count) == [23 * 16_000])
    #expect(core.requests.map(\.offsetSeconds) == [0])
}
@Test func silenceCutDoesNotOverlap() async throws {                           // 決定 6 (b)
    let core = FakeWhisperCore(windows: [[seg(0, 8, "一"), seg(8, 16, "二")], [seg(0, 10, "三"), seg(10, 23, "四")]])
    let u = try await run(core, tone(16) + silence(2) + tone(22))
    #expect(core.requests.map(\.samples.count) == [17 * 16_000, 23 * 16_000])  // 合計が全長 = 重なりなし
    #expect(u.map(\.start.seconds) == [0, 8, 17, 27])
    #expect(u.map(\.text) == ["一", "二", "三", "四"])
}
@Test func hardCutOverlapsAndKeepsEachSegmentOnce() async throws {             // 決定 6 (c)。窓 2 は 15 秒から読む
    let core = FakeWhisperCore(windows: [
        [seg(0, 9, "一"), seg(9, 18, "二"), seg(18, 21.5, "三"), seg(21.5, 25, "四（前の窓）")],
        [seg(0, 3, "二（後の窓）"), seg(3, 6.5, "三（後の窓）"), seg(6.5, 12, "四"), seg(12, 25, "五")]])
    let u = try await run(core, tone(40))
    #expect(core.requests.map(\.samples.count) == [25 * 16_000, 25 * 16_000])
    #expect(u.map(\.text) == ["一", "二", "三", "四", "五"])
    #expect(u.map(\.start.seconds) == [0, 9, 18, 21.5, 27])
}
@Test func timesAreShiftedAndMonotonic() async throws {                        // 決定 6 (d)。45 秒は 0・15・35 秒から読む 3 窓
    let core = FakeWhisperCore(windows: [[seg(1, 3, "a")], [seg(6, 8, "b")], [seg(6, 8, "c")]])
    let u = try await run(core, tone(45))
    #expect(u.map(\.start.seconds) == [1, 21, 41])
    #expect(u.map { $0.end?.seconds } == [3, 23, 43])
    #expect(zip(u, u.dropFirst()).allSatisfy { $0.start.seconds < $1.start.seconds })
}
@Test func requestsCarryOnlyTheWindowSamples()       // tone(45)、language .en、hints ["所沢"] → samples.count == [25, 30, 10] × 16_000、
    // 全窓で language == .en・prompt == "所沢"・mode == .batch（前の窓の末尾をプロンプトに足さない＝設計書のアンチゴール）
@Test func silenceFilterUsesTheWindowPCM() async throws {
    // 17 秒で切れる。窓 2（17–40 秒）の 11–15 秒 = ファイルの 28–32 秒は無音、15–23 秒 = 32–40 秒は tone
    let core = FakeWhisperCore(windows: [[seg(0, 16, "一")], [seg(11, 15, "幻"), seg(15, 23, "はい")]])
    let u = try await run(core, tone(16) + silence(2) + tone(10) + silence(4) + tone(8))
    #expect(u.map(\.text) == ["一", "はい"])
}
@Test func silentWindowIsStillDecodedAndYieldsNothing() async throws {
    let core = FakeWhisperCore(windows: [[seg(0, 16, "一")], [seg(2, 10, "幻")]])
    let u = try await run(core, tone(16) + silence(24))          // 18 秒で切れ、窓 2 はまるごと無音
    #expect(core.runCount == 2)
    #expect(u.map(\.text) == ["一"])
}
@Test func logsOneLinePerWindow() async throws {
    let lines = ProgressLog()   // テスト内の小さな Mutex<[String]> の箱
    _ = try await run(FakeWhisperCore(windows: []), tone(40), log: { lines.append($0) })
    #expect(lines.values == ["文字起こし 窓 1/2（0 分 / 1 分）", "文字起こし 窓 2/2（1 分 / 1 分）"])
}
@Test func progressReachesHalfAfterTheFirstOfTwoEqualWindows()   // tone(40)、窓 1 の終わりで 0.5、単調、最後は 1.0
@Test func cancellationDuringFirstWindowNeverStartsTheSecond() async throws {
    let core = FakeWhisperCore(windows: [(0..<20).map { seg(Double($0), Double($0 + 1), "\($0)") }], delay: .milliseconds(100))
    let file = try wavFile(tone(40))
    let t = Task { try await WhisperBatchTranscriber(core: core, gate: BatchGate(), windows: small, log: { _ in })
        .transcribe(file: file, language: .ja, hints: [], progress: { _ in }) }
    try await waitUntil { core.emittedCount >= 1 }
    t.cancel()
    await #expect(throws: CancellationError.self) { _ = try await t.value }
    #expect(core.runCount == 1)
}
@Test func pausedGateHoldsTheNextWindow() async throws {
    // 窓 1 の唯一のセグメントが出る前（delay 中）に pause → そのセグメントの境界で中断し、窓 1 の再開（offset 9）も窓 2 も始めない
    let gate = BatchGate()
    let core = FakeWhisperCore(windows: [[seg(0, 9, "一")], [seg(6.5, 12, "四")]], delay: .milliseconds(200))
    let file = try wavFile(tone(40))
    let t = Task { try await WhisperBatchTranscriber(core: core, gate: gate, windows: small, log: { _ in })
        .transcribe(file: file, language: .ja, hints: [], progress: { _ in }) }
    try await waitUntil { core.runCount >= 1 }
    await gate.pause()
    try await waitUntil { core.emittedCount >= 1 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(core.runCount == 1)
    await gate.resume()
    #expect(try await t.value.map(\.text) == ["一", "四"])
    #expect(core.requests.map(\.offsetSeconds) == [0, 9, 0])   // 窓 1 の再開は台本に残りが無く空で終わる
}
@Test func pauseInsideAWindowResumesFromItsLastSegment()   // tone(40)、台本 [[0–9「一」], [6.5–12「四」, 12–18「五」, 18–25「六」]]、delay 200 ms。
    // emittedCount >= 2（一・四）で pause、>= 3（五）を待って 300 ms 後も runCount == 2、resume → offsetSeconds == [0, 0, 18]、本文 [一, 四, 五, 六]
@Test func non16kMonoWAVIsInvalidAudio()   // 44 100 Hz のヘッダ（WAVFile.header(sampleRate: 44_100, …)）+ 本体 → throws TranscriptionError.invalidAudio、core.runCount == 0
@Test func emptyFileMakesOneEmptyRun()     // wavFile([]) → runCount 1、samples.count 0、結果 []

// FinalTranscriptionRunnerTests に追加
@Test func importedTrackRunsThroughWindows()
    // tracks/import-000.wav に tone(40)（setUp は無音を書くので、このテストは自分で tone を書く）、source .imported、startOffset 0。
    // runner の transcriber は WhisperBatchTranscriber(core: FakeWhisperCore(windows: [[seg(1, 3, "前")], [seg(6.5, 8, "後")]]), gate:, windows: small)
    // → core.runCount == 2、raw.utterances の start == [1, 21.5]、speaker == [.unknown, .unknown]
```

既存の `WhisperBatchTranscriberTests`（既定の `Config` で 2〜20 秒の 1 窓）はそのまま通ること。

- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter 'WhisperBatchTranscriberTests|FinalTranscriptionRunnerTests'` → Expected: `extra argument 'windows' in call` でビルド失敗
- [ ] **Step 3: `FakeWhisperCore.init(windows:delay:)`、`WhisperBatchTranscriber` の窓の流れ、`TranscriberFactory.whisperBatch(…, log:)` を実装する** — ログの文は `"文字起こし 窓 \(i + 1)/\(n)（\(a) 分 / \(b) 分）"`（括弧は全角、a・b は前提 6 のとおり四捨五入）。進捗は前提 5 の写し方で既存の `report` に渡す。`PCMAudio.readMono16k` はこの型から呼ばない
- [ ] **Step 4: 通過を確かめる** — Run: `swift test && scripts/e2e-check.sh --quick` → Expected: 全テスト PASS（904 + この計画で足した分）、E2E 0 failed
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription Sources/AutoNoteTestSupport/FakeWhisperCore.swift \
    Tests/AutoNoteCoreTests/Transcription/WhisperBatchTranscriberTests.swift Tests/AutoNoteCoreTests/Transcription/FinalTranscriptionRunnerTests.swift
git commit -m "feat(core): run batch whisper window by window so memory stays flat for long recordings" -m "<trailers>"
```

---

### Task 4: `dev transcribe --engine whisper` を同じ窓の経路に（非 16 kHz は一時 WAV）と E2E 08.2

**Files:**
- Modify: `Sources/AutoNoteCore/Audio/AudioImporter.swift`、`Sources/autonote/DevTranscribe.swift`、`scripts/e2e-check.sh`
- Test: `Tests/AutoNoteCoreTests/Audio/AudioImporterTests.swift`

**Interfaces:**
- Consumes: `WAVFile.info`・`sampleCount`・`readSamples(_:in:)`（Task 1）、`TranscriberFactory.whisperBatch(modelURL:machine:gate:log:)`（Task 3）
- Produces:
  - `public static func convertToMono16kWAV(from source: URL, to wavURL: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Int`（`AudioImporter`。戻り値はサンプル数）— 今の `importFile` の「最初の音声トラックを読む → `transcodeQueue` 上で `transcode` → 取り消しは `withTaskCancellationHandler`」をそのまま切り出したもの。拡張子は確かめない。トラックが無ければ `ImportError.noAudioTrack`、読めなければ `ImportError.unreadable`。`importFile` はこれを使う（拡張子と読めるかの確認・ID の決め方・失敗時の後始末は今のまま）

- [ ] **Step 1: 失敗するテストを書く**

```swift
// AudioImporterTests に追加（既存の synthesize は 44.1 kHz 2 ch の 440 Hz）
@Test func convertToMono16kWAVWritesSamplesAndHeader() async throws {
    let dir = try TemporaryDirectory.make()
    let src = try synthesize("wav", in: dir, seconds: 3)
    let out = dir.appending(path: "out.wav")
    let n = try await AudioImporter.convertToMono16kWAV(from: src, to: out)
    let info = try WAVFile.info(out)
    #expect(info.sampleRate == 16_000 && info.channels == 1 && info.bitsPerSample == 16)
    #expect(abs(n - 48_000) <= 800)
    #expect(try WAVFile.sampleCount(out) == n)
    #expect(try WAVFile.readSamples(out, in: 0..<n).contains { abs(Int($0)) > 8000 })
}
@Test func convertRejectsGarbage()   // "this is not audio" の .m4a → ImportError の .unreadable か .noAudioTrack
```

E2E（`scripts/e2e-check.sh`）: 合成 WAV の補助と 08.2 を足す。

```bash
# 08.x 共通: 16 kHz mono 16-bit の WAV を書く（1 秒の 440 Hz（振幅 8000）+ 2 秒の無音を繰り返す）。python3 の標準ライブラリだけ
make_tone_wav() {   # make_tone_wav <出力> <秒>
    python3 -I -c 'import math,struct,sys,wave
sec=int(sys.argv[2]); unit=b"".join(struct.pack("<h",int(8000*math.sin(2*math.pi*440*i/16000))) for i in range(16000))+b"\0"*64000
w=wave.open(sys.argv[1],"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
for _ in range(sec//3): w.writeframesraw(unit)
w.close()' "$1" "$2"
}
DUMMY_GGML=tools/whisper.cpp/models/for-tests-ggml-tiny.bin   # 推論は空振りするが、読み込み・変換・メルは実モデルと同じ（監査 C）
```

`check_dev_transcribe_whisper_resampled`（`CURRENT="08.2 dev transcribe whisper が 44.1 kHz ステレオの WAV を変換して窓で流す"`）: `--quick` は skip、python3・jq・`${DUMMY_GGML}` が無ければ skip、`cli_or_skip`。`make_tone_wav "${WORK}/t30.wav" 30` → `afconvert -f WAVE -d LEI16@44100 -c 2 "${WORK}/t30.wav" "${WORK}/t30-44k.wav"` → `run_timeout 120 "${AUTONOTE_CLI}" dev transcribe "${WORK}/t30-44k.wav" --engine whisper --model-path "${DUMMY_GGML}"`。exit 0、`LAST_LOG` に `文字起こし 窓 1/1（` の行がある、`summary.audio_seconds` が 29.9〜30.1 なら PASS。CHECKS の `check_dev_transcribe_whisper_live` の直後

- [ ] **Step 2: 失敗を確かめる** — Run: `swift test --filter AudioImporterTests && swift build --product autonote && scripts/e2e-check.sh` → Expected: `convertToMono16kWAV` が無くビルド失敗（E2E は Step 3 の後で 08.2 が意味を持つ。今の CLI は窓のログを出さないので 08.2 は FAIL）
- [ ] **Step 3: `convertToMono16kWAV` を切り出し、`DevTranscribe` の whisper 経路を書き換える**
  - `private static func batchInput(_ o: Options) async throws -> (file: URL, samples: Int, temporary: [URL])`: 入力の `WAVFile.info` が 16 000 Hz・1 ch・16 bit ならそのまま、そうでなければ（`info` が投げる場合も）一時ディレクトリの `autonote-dev-transcribe-<UUID>.wav` に `AudioImporter.convertToMono16kWAV` で書く。`--max-seconds` で切るときは、先頭 `Int(max × 16 000)` サンプルを別の一時 WAV に 60 秒（960 000 サンプル）ずつ `readSamples(_:in:)` で写す（ヘッダは先にサンプル数を入れて書く）
  - whisper の分岐: `batchInput` → `audioSeconds = Double(samples) / 16 000` → `batch.transcribe(file:)`。`defer` で `temporary` を消す。`makeBatch` の `--model-path` 経路は `whisperBatch(…, log: { DevCommands.printError($0) })`（stderr に 1 行ずつ）。モデル名の経路（`factory.makeBatch`）は os ログのまま
  - `fileInput` は live 用だけになる: 引数 `truncatedCopy` と一時 WAV の分岐を消し、`[Int16]` を返す（`--engine whisper-live` と dictation の流れは変えない）
- [ ] **Step 4: 通過を確かめる** — Run: `swift test --filter AudioImporterTests && scripts/e2e-check.sh` → Expected: PASS。E2E 0 failed（08.2 PASS。04.3 は ggml-base と `tools/samples/ja-5min.wav` がある環境で PASS、無ければ従来どおり SKIP）
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Audio/AudioImporter.swift Tests/AutoNoteCoreTests/Audio/AudioImporterTests.swift \
    Sources/autonote/DevTranscribe.swift scripts/e2e-check.sh
git commit -m "feat(cli): dev transcribe whisper converts input to a temp 16 kHz WAV and uses the windowed path (E2E 08.2)" -m "<trailers>"
```

---

### Task 5: E2E 08.1（10 分と 60 分の max RSS 差 ≤ 100 MB）と overview §8j

**Files:**
- Modify: `scripts/e2e-check.sh`、`docs/superpowers/plans/2026-10-25-autonote-plans-overview.md`

**Interfaces:**
- Consumes: `make_tone_wav`・`DUMMY_GGML`（Task 4）、Task 3 の窓のログ行
- Produces: E2E 40 項目（38 + 08.1・08.2）

- [ ] **Step 1: E2E 項目を書く** — `check_batch_memory_flat`（`CURRENT="08.1 dev transcribe whisper の max RSS が 10 分と 60 分で 100 MB 以内の差"`）: `--quick` は skip、python3・`${DUMMY_GGML}` が無ければ skip、`cli_or_skip`。`make_tone_wav "${WORK}/m10.wav" 600` と `make_tone_wav "${WORK}/m60.wav" 3600`（数秒で作れる）。それぞれ `run_timeout 600 /usr/bin/time -l "${AUTONOTE_CLI}" dev transcribe <wav> --engine whisper --model-path "${DUMMY_GGML}"` を走らせ、exit 0 と、`awk '/maximum resident set size/ {print $1}' "${LAST_LOG}"` の値を取る。10 分の LAST_LOG に `文字起こし 窓 1/1（` があること、60 分の最後の窓の行が `窓 N/N` で N ≥ 5 であること（窓の経路を通った証拠）。`rss60 - rss10 <= 104857600` なら PASS（メッセージに両方の MB と 60 分の窓の数）。超えたら FAIL に両方の値を出す。合成 WAV は項目の終わりに消す（60 分で約 115 MB）。CHECKS の 08.2 の直後
- [ ] **Step 2: 回して確かめる** — Run: `scripts/e2e-check.sh`（マシンがアイドルのとき）→ Expected: 08.1 PASS（参考: 窓分割前は 10 分 443 MB → 60 分 1,182 MB で差 739 MB）、40 項目で 0 failed。かかった時間と 2 つの max RSS を報告に書く
- [ ] **Step 3: overview に §8j を足す** — §8i の後、§9 の前に「## 8j. 計画 08 の実装で確定した変更（2026-10-28。以後の作業はこれに従う）」。箇条書きで: `WAVFile.sampleCount` / `readSamples(_:in:)`（範囲読み、ヘッダの data サイズは実ファイル長で頭打ち、`readSamples(_:)` も全量の `Data` を作らない）; `BatchWindowPlanner`（`Config` 既定 nominal 600・lookback 60・overlap 5・tailMerge 120 秒、無音は `SilenceDetector` の 0.01 / 0.8 秒で最長・同点は後ろ、中央で切って重ねない、無ければ名目で切って前後 5 秒ずつ読む、中点 == 切れ目は後の窓、残り ≤ nominal + tailMerge は最後の窓）; `BatchWindow{index, read, owned, isLast}`; `WhisperBatchTranscriber(core:gate:windows:log:)`（16 kHz mono 16-bit 以外は `invalidAudio`、窓ごとに `BatchGate` と取り消しを見る、再開ループは窓の中、無音判定は窓の PCM、無音の窓も whisper に掛ける、`no_speech` は出さない、`RepetitionFilter` は全窓に 1 回、ログ「文字起こし 窓 i/n（a 分 / b 分）」は既定 os Logger・CLI は stderr、GUI の見出しに割合は出さない）; `FakeWhisperCore(windows:delay:)`（offset 0 の呼び出しを新しい窓と数える）; `AudioImporter.convertToMono16kWAV(from:to:progress:)`; `dev transcribe --engine whisper` は非 16 kHz を一時 WAV にし `fileInput` は live 専用; E2E 40 項目（08.1 は 10 分と 60 分の max RSS 差 ≤ 100 MiB、08.2 は 44.1 kHz ステレオ入力。どちらもダミー ggml を使い `--quick` で skip）; 残課題: 録音中の逐次処理（窓のパイプライン）は未着手（利用者の決定待ち）、監査 P2・P3 は別計画、実モデルの golden は作らない（固定は `FakeWhisperCore`）
- [ ] **Step 4: コミット**

```bash
git add scripts/e2e-check.sh docs/superpowers/plans/2026-10-25-autonote-plans-overview.md
git commit -m "test(e2e): batch whisper memory stays flat from 10 to 60 minutes (08.1); record plan 08 in the overview" -m "<trailers>"
```
