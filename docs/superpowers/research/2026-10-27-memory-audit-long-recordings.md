# 長時間録音のメモリ監査（2026-10-27, branch plan-07 @ c20d68e）

問い: 2〜3 時間の録音で OOM になる可能性、録音時間に比例してメモリが増え続ける箇所はあるか。

## 結論

- **録音中・ライブ文字起こし中は、録音時間に比例して増える構造はほぼない。** 音声はリングバッファ（固定）→ 5 分ごとの WAV へ逐次書き出しで、PCM を配列に溜めていない。実測の RSS の傾きは録音で 約 0.05 MB/分（5 分以降は横ばい）、ライブ（Dictation）で 0.2〜0.5 MB/分。3 時間でも数十 MB 以下。
- **OOM の危険が現実にあるのは停止後のバッチ文字起こし（whisper）。** トラック 1 本（休止がなければ録音全体が 1 本の WAV）を丸ごとメモリに読み、Int16 → Float 変換、whisper.cpp 内部でもさらにコピーとメルスペクトログラムを作る。録音 1 分あたり約 13〜15 MB が同時に乗る。**2 時間で約 1.6〜1.8 GB、3 時間で約 2.4〜2.7 GB**（モデル本体は別。large-v3-turbo なら +1.5 GB 前後）。8 GB の Mac で他のアプリと並ぶと、スワップが激しくなるか jetsam で落ちる範囲に入る。
- 既存の「500 MB で止める」仕組み（`RecordingSession.diskStopBytes`, RecordingSession.swift:24, 判定 :248, テスト `stopsBelow500MBAndKeepsAudio` RecordingSessionMonitorTests.swift:40）は**ディスクの空き容量**の下限で、メモリの上限ではない。メモリを見て止める・分割する仕組みはコードにない（`physicalMemory` / `os_proc_available_memory` の参照なし）。

## 観点ごとの監査

### 1. 音声取り込み — 固定（問題なし）

| 箇所 | 判定 | 根拠 |
|---|---|---|
| `AudioRingBuffer` Audio/AudioRingBuffer.swift:40-50 | 固定 | init で確保した固定長リング。マイク・タップとも 10 秒分（MicrophoneSource.swift:81, ProcessTapSource.swift:178）。溢れたら捨てて `dropped` を数える |
| `SourceDrain` Audio/SourceDrain.swift:79-114 | 固定 | 20 ms ごとにリングから読み、チャンクにして `onBuffer` へ。`buffer` は使い回し |
| `SampleConverter` Audio/SampleConverter.swift:68-91 | 固定 | `mono` は `removeAll(keepingCapacity:)`、AVAudioPCMBuffer は大きいチャンクで一度だけ拡張 |
| `ChunkQueue` Audio/RecordingPipeline.swift:13-14 | 上限なし（実害なし） | `AsyncStream.makeStream()` 既定の `.unbounded`。消費側（WAV 書き込み）がディスク I/O に詰まると溜まるが、通常は即時消化。実測でも増えない |
| `WAVSegmentWriter` Audio/WAVSegmentWriter.swift:97-108 | 固定 | `FileHandle` に逐次書き込み、5 分ごとにファイルを切り替え。コメント通り「nothing is buffered whole」 |
| `TimelineAligner` / `TrackStatistics` | 固定 | 数値カウンタのみ |
| `Manifest.tracks` / `pauses` / `bookmarks` | 時間比例だが極小 | 5 分ごとに 1 件 × 2 トラック。3 時間で 72 件 |
| `ManifestSaver` の Task 連鎖 RecordingPipeline.swift:66-83 | 極小 | 保存ごとに前の Task を捕捉する連鎖。保存は 5 分ごと＋操作時のみ |
| `EventBroadcaster` Audio/EventBroadcaster.swift:12 | 上限なし（実害なし） | イベントは低頻度（開始・停止・警告） |

### 2. ライブ文字起こし

| 箇所 | 判定 | 根拠 |
|---|---|---|
| `RecordingSession.audio(for:)` RecordingSession.swift:101 | 上限なし（条件つき） | `.unbounded` の AsyncStream。消費側 `LiveTranscriptionWiring` Presentation/LiveTranscriptionWiring.swift:92-97 は `await feed.feed(chunk)` で 1 個ずつ処理するので、`LiveFeed` actor が長く塞がるとチャンク（約 64 KB/秒・2 トラック分）が溜まる |
| `WhisperLiveTranscriber.buffer` Whisper/WhisperLiveTranscriber.swift:57, 88-92 | 固定 | 窓の開始より前は `removeFirst` で捨てる（窓は最大 8 秒, ChunkPlanner.swift:14） |
| **`WhisperLiveTranscriber.jobs`** WhisperLiveTranscriber.swift:79-82, 104-113 | **条件つきで無限成長** | partial は最新 1 件だけ残すが、commit は「決して捨てない」。各 commit は最大 8 秒分の `[Int16]`（≈256 KB）を持つ。デコードが実時間より遅い（RTF > 1: Intel で Metal なし、大きいモデル、バッチと同時実行など）と、未処理の commit が録音時間に比例して溜まる。最悪（ほぼ全く追いつかない）で 2 トラック × 32 KB/秒 ≈ **230 MB/時**。Apple Silicon で turbo なら通常は追いつく |
| `AppleLiveTranscriber` の入力 Apple/AppleLiveTranscriber.swift:75, 113 | 上限なし（条件つき） | analyzer への `AsyncStream<AnalyzerInput>` が `.unbounded`。SpeechAnalyzer が遅れれば AVAudioPCMBuffer が溜まる。実測（Dictation）では追いついている |
| `AppleLiveTranscriber.scheduleFinalize` :179-187 | 極小 | 無音境界ごとの Task 連鎖。3 時間で数千件 × 数百 B |
| `TimelineMapper.segments` Shared/TimelineMapper.swift:15-26 | 時間比例だが極小 | 一時停止・ドロップアウトごとに 1 件だけ |
| **`LiveFeed.utterances`** Live/LiveFeed.swift:47, 136-147 | **時間比例（小）** | 確定セグメントを全件メモリに保持（設計上必要）。テキストのみで 1 件 200〜300 B、3 時間（両トラック合わせて数千〜1 万件）で **数 MB**。ただし partial 1 件ごとに `snapshot()`（全件コピー＋置換＋ソート :110-117）、確定ごとに最大 5 秒に 1 回 live.json 全体を書き直す（:165-180）ので、**CPU と一時的な確保は件数に比例して重くなる**（メモリが残り続けるわけではない） |
| `LiveTranscriptionWiring.latest` / `AppModel.live` / `LiveTranscriptBuffer.lines` Presentation/LiveTranscriptBuffer.swift:12-14 | 時間比例（小） | 同じ全件リストのコピーが 2〜3 個。数 MB 程度。ストリームは `.bufferingNewest(1)` で溜まらない |
| `LiveTranscriptView` AutoNoteApp/MainWindow/LiveTranscriptView.swift:15-22, 36-38 | 未計測（要 GUI 計測） | `LazyVStack` + `ForEach(Array(lines.enumerated()), id: \.offset)` + 全体に `.textSelection(.enabled)`。更新のたびに全件の配列を作り直して diff、`onChange(of: lines)` も全件比較。メモリよりも CPU が件数に比例。macOS の LazyVStack が一度作った行を手放すかは実アプリで測る必要がある（今回は App を起動していない） |

### 3. レベルメーター — 固定

| 箇所 | 判定 | 根拠 |
|---|---|---|
| `RecentPeakWindow` Audio/RecentPeakWindow.swift:20-23 | 固定 | 観測のたびに 1 秒より古い要素を削除。最大でも 1 秒分のチャンク数（system で 100 件前後） |
| `TrackLevel` / `InputLevelTracker` Presentation/InputLevel.swift:16-36 | 固定 | カウンタ 1 個 |
| `SilenceMonitor` Audio/SilenceMonitor.swift | 固定 | スカラーのみ |

### 4. 停止後のバッチ — **ここが本命**

| 箇所 | 判定 | 根拠 |
|---|---|---|
| `SegmentMerger.merge` Audio/SegmentMerger.swift:47-51 | 固定 | 5 分のセグメントを 1 つずつ読んで追記（1 回あたり ≈ 9.6 MB × 2） |
| **`WAVFile.readSamples`** Audio/WAVFile.swift:41-54 | **録音長に比例** | `Data(contentsOf:)` でファイル全体（2 時間で 230 MB）を読み、さらに `[Int16]` にコピー（230 MB）。一瞬は両方が乗る |
| **`WhisperBatchTranscriber.transcribe`** Whisper/WhisperBatchTranscriber.swift:20-21, 67 | **録音長に比例** | `pcm`（Int16, 2 B/サンプル）と `samples`（Float, 4 B/サンプル）を文字起こしの最後まで両方保持（`pcm` は最後の `SilenceDetector` 用） |
| **whisper.cpp `log_mel_spectrogram`** tools/whisper.cpp/src/whisper.cpp:3256-3276 | **録音長に比例** | `samples_padded`（Float の全量コピー, 4 B/サンプル）とメル `n_mel × (サンプル数/160)` の float。メルは 80 mel で 1.9 MB/分、128 mel（large-v3 / turbo）で 3.1 MB/分。メルは `whisper_state` に残る |
| 一時停止→再開のたび | 比例 | `while true` で `whisper_full` を `offset_ms` つきで呼び直すので、そのたびにメル全体を作り直す（確保は再利用だが CPU は重い） |
| `FinalTranscriptionRunner` Batch/FinalTranscriptionRunner.swift:44-61 | 逐次 | mic → system の順に 1 本ずつ。2 本が同時に乗ることはない |
| `LazyBatchTranscriber` AutoNoteApp/AppEnvironment.swift:366-389 | ジョブごと | ジョブごとに作り直すので、メルを持った `whisper_state` はジョブ後に解放される |
| `EchoDeduplicator` Transcript/EchoDeduplicator.swift:24-41 | 一時的 | 件数の積で CPU は増えるが、メモリは一時的 |
| 議事録 `PromptBuilder.plan` Minutes/PromptBuilder.swift:63-110 | 分割あり | しきい値を超えると部分議事録に分割。プロンプト全文は 3 時間でも数百 KB〜数 MB 程度 |
| `ProcessRunner` stdout/stderr Minutes/ProcessRunner.swift:110-130 | 上限なし（実害なし） | claude の出力は小さい |
| `AudioImporter` | 同じ問題 | 取り込み音声も分割せず `import-000.wav` 1 本 → バッチで丸ごと読む |

1 分あたりの同時確保（理論値）: `Data` 1.92 + `[Int16]` 1.92（読み込み中のみ）+ Float 3.84 + `samples_padded` 3.84 + メル 1.9〜3.1 ≈ **13〜15 MB/分**。

### 5. ログ・通知・ジョブ（1 Hz ティック） — 固定

| 箇所 | 判定 | 根拠 |
|---|---|---|
| `AppModel.updateElapsed` Presentation/AppModel.swift:363-378 | 固定 | 値を上書きするだけ |
| `AppModel.prompts` :173, 283-310 | 固定 | id で重複を除く。会議の数に比例するだけ |
| `AppModel.automationFailures` :410-413 | 固定 | 名前＋会議ごとに 1 件 |
| `relayQueueNotices` の `posted` AutoNoteApp/AppEnvironment.swift:244-266 | 会議数に比例（極小） | 通知ごとにキー 1 個。録音時間には比例しない |
| ロガー | 固定 | `os.Logger` のみ（アプリ内にバッファなし） |

### 6. 既存の上限

- `diskWarningBytes = 1 GB`、`diskStopBytes = 500 MB`（RecordingSession.swift:22-26）。10 秒ごとに `disk.availableBytes(for: recordingsDirectory)` を見る。**ディスクの空き**であってメモリではない。
- メモリに関する上限・チェックは無い。

## 実測

環境: Intel Mac（x86_64）, 32 GB, debug ビルド `.build/debug/autonote`, `AUTONOTE_DATA_DIR=/tmp/an-mem.*`（終了後に削除）。生データ: `memory-audit-raw/`（同じディレクトリ）。

### A. 録音（`dev record --seconds 420`、`say -v Kyoko` を流し続ける）

mic 4195 チャンク / system 39314 チャンク、各 2 ファイル、`status: recorded`。

| 経過 (s) | 11 | 61 | 121 | 181 | 241 | 301 | 362 | 412 |
|---|---|---|---|---|---|---|---|---|
| RSS (MB) | 21.83 | 21.91 | 22.01 | 22.05 | 22.07 | 22.13 | 22.13 | 22.13 |

傾き: 全体 **0.046 MB/分**（11→412 s で +0.30 MB）。300 s 以降は 0（横ばい、5 分のセグメント切り替え時に +50 KB）。外挿: 2 時間 +5 MB 以下、3 時間 +8 MB 以下（実際は横ばいなのでもっと小さい）。

### B. ライブ文字起こし（`dev transcribe live7m.wav --engine dictation --realtime`、7 分、確定 21 件）

SpeechTranscriber はこの Intel Mac で `isAvailable == false` のため測れず。whisper-live は実モデルが手元に無いため測れず（`tools/whisper.cpp/models/for-tests-*` はダミー）。CLI の経路は `LiveTranscriber` 直結で `LiveFeed` / UI を通らない。

| 経過 (s) | 20 | 60 | 120 | 180 | 241 | 301 | 361 | 411 |
|---|---|---|---|---|---|---|---|---|
| RSS (MB) | 50.55 | 51.48 | 52.21 | 53.07 | 53.39 | 53.59 | 53.75 | 53.84 |

傾き: 全体 **0.50 MB/分**、後半（201→411 s）**0.23 MB/分**（減速傾向）。線形外挿の上限: 2 時間 +28〜60 MB、3 時間 +40〜90 MB。Apple のフレームワーク内部のキャッシュが主と見られ、OOM の要因にはならない。

### C. バッチ whisper（`dev transcribe <file> --engine whisper --model-path for-tests-ggml-tiny.bin`、`/usr/bin/time -l`）

ダミーモデル（80 mel）なので推論は空振りだが、読み込み・変換・メル計算のメモリは実モデルと同じ。CLI は `fileInput` で Int16 のコピーをもう 1 つ持つ（+1.9 MB/分、アプリには無い）。

| 音声長 | max RSS | peak footprint |
|---|---|---|
| 19 秒 | 295 MB | 256 MB |
| 10 分 | 443 MB | 363 MB |
| 30 分 | 738 MB | 533 MB |
| 60 分 | 1,182 MB | 882 MB |

傾き（10→60 分）: max RSS **14.8 MB/分**、footprint **10.4 MB/分**。理論値（CLI のコピー込み 15.4 MB/分）と一致。

アプリでの外挿（CLI のコピー −1.9 MB/分、128 mel のモデルなら +1.2 MB/分 → 約 14 MB/分、モデル重みは別）:

| 録音長 | バッチのピーク（音声分） | + large-v3-turbo の重み (概算) |
|---|---|---|
| 1 時間 | 約 0.9〜1.1 GB | 約 2.5 GB |
| 2 時間 | 約 1.6〜1.8 GB | 約 3.2 GB |
| 3 時間 | 約 2.4〜2.7 GB | 約 4 GB |

（録音に一時停止があればトラックが分かれ、そのぶん 1 本あたりは小さくなる。）

## 修正案（優先度順）

1. **P1 — バッチを窓単位で流す（OOM の本命を消す）。** `WhisperBatchTranscriber` をファイル全体ではなく 5〜10 分（または `SegmentMerger` 前の 5 分セグメント単位）の窓で `whisper_full` にかけ、窓の境界は数秒重ねて `OverlapTrimmer`／時刻オフセットで継ぐ。メモリは録音長によらず「窓 1 本分」（10 分窓で約 150 MB）で一定になる。`SilenceDetector.hasSpeech` も窓ごとの PCM で判定する。一時停止→再開の作り直しも窓の中だけになる。
   - 最小の手当て（すぐ入れられる）: (a) `WAVFile.readSamples` を `FileHandle` で直接 `[Int16]` に読む（`Data` 全量のコピーを消す、−1.9 MB/分のピーク）、(b) `pcm` を Float 化したあとで手放し、無音判定は Float 側か窓ごとの読み直しで行う（−1.9 MB/分）。これだけで約 10 MB/分（3 時間で約 1.8 GB）に下がるが、比例は残る。
2. **P2 — whisper-live の commit 滞留に上限を付ける。** `jobs` の未処理 commit が N 件（例: 30 秒〜1 分分）を超えたら古い commit を捨てて空の確定を流す、または live を落として「ライブ表示を止めました（議事録は録音から作ります）」と出す。RTF > 1 の機材（Intel・大モデル・バッチと同時）で録音時間に比例して増えるのを止める。あわせて `RecordingSession.audio(for:)` の AsyncStream を `.bufferingNewest(…)`（数秒分）にして、ライブ側の詰まりが音声チャンクの滞留にならないようにする（録音ファイルには影響しない）。
3. **P3 — ライブ表示の件数比例の処理を軽くする。** `LiveFeed.snapshot()` を partial ごとに全件ソートせず、確定済みを順序付きで持って差分を追加する形にし、live.json の全件書き直しを追記型か間隔延長にする。`LiveTranscriptView` は `id: \.offset` ではなく安定した id（start + speaker）にし、`textSelection` を行単位にする。メモリよりも 2〜3 時間目の CPU と UI の引っかかり対策。GUI での実測（3 時間相当の行数を流して RSS と CPU を見る）を別に行う。

## 未計測・制約

- SpeechTranscriber（Intel では使えない）、whisper-live（実モデルなし）、`LiveFeed`＋SwiftUI の表示（App を起動しない条件）は実測していない。コードの読みから評価した。
- バッチはダミーモデルで計測。重み・Metal バッファ・KV キャッシュは録音長によらない固定分として別に見積もった。
- 実測は 7 分 + 7 分（並行）+ バッチ約 2.5 分。2〜3 時間の数値は外挿。
